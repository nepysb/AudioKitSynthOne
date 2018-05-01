//
//  AKSynthOneDSPKernel.mm
//  AudioKitSynthOne
//
//  Created by Marcus W. Hobbs aka Marcus Satellite on 1/27/18.
//  Copyright © 2018 AudioKit. All rights reserved.
//

#import <AudioKit/AudioKit-swift.h>
#import "AKSynthOneDSPKernel.hpp"
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <AVFoundation/AVFoundation.h>
#import "AEArray.h"
#import "AEMessageQueue.h"

#define AKS1_SAMPLE_RATE (44100.f)
#define AKS1_RELEASE_AMPLITUDE_THRESHOLD (0.000000000232831f) // 1/2^32
#define AKS1_PORTAMENTO_HALF_TIME (0.1f)
#define AKS1_DEBUG_DSP_LOGGING (0)
#define AKS1_DEBUG_NOTE_STATE_LOGGING (0)
#define AKS1_DEPENDENT_PARAM_TAPER (0.4f)

// Relative note number to frequency
static inline float nnToHz(float noteNumber) {
    return exp2(noteNumber/12.f);
}

// Convert note number to [possibly] microtonal frequency.  12ET is the default.
// Profiling shows that while this takes a special Swift lock it still resolves to ~0% of CPU on a device
static inline double tuningTableNoteToHz(int noteNumber) {
    return [AKPolyphonicNode.tuningTable frequencyForNoteNumber:noteNumber];
}

// helper for arp/seq
struct AKSynthOneDSPKernel::SeqNoteNumber {
    
    int noteNumber;
    int onOff;
    
    void init() {
        noteNumber = 60;
        onOff = 1;
    }
    
    void init(int nn, int o) {
        noteNumber = nn;
        onOff = o;
    }
};

// MARK: NoteState: atomic unit of a "note"
struct AKSynthOneDSPKernel::NoteState {
    AKSynthOneDSPKernel* kernel;
    
    enum NoteStateStage { stageOff, stageOn, stageRelease };
    NoteStateStage stage = stageOff;
    
    float internalGate = 0;
    float amp = 0;
    float filter = 0;
    int rootNoteNumber = 0; // -1 denotes an invalid note number
    
    //Amplitude ADSR
    sp_adsr *adsr;
    
    //Filter Cutoff Frequency ADSR
    sp_adsr *fadsr;
    
    //Morphing Oscillator 1 & 2
    sp_oscmorph *oscmorph1;
    sp_oscmorph *oscmorph2;
    sp_crossfade *morphCrossFade;
    
    //Subwoofer OSC
    sp_osc *subOsc;
    
    //FM OSC
    sp_fosc *fmOsc;
    
    //NOISE OSC
    sp_noise *noise;
    
    //FILTERS
    sp_moogladder *loPass;
    sp_buthp *hiPass;
    sp_butbp *bandPass;
    sp_crossfade *filterCrossFade;
    
    inline float getParam(AKSynthOneParameter param) {
        return kernel->getAK1Parameter(param);
    }
    
    void init() {
        // OSC AMPLITUDE ENVELOPE
        sp_adsr_create(&adsr);
        sp_adsr_init(kernel->sp, adsr);
        
        // FILTER FREQUENCY ENVELOPE
        sp_adsr_create(&fadsr);
        sp_adsr_init(kernel->sp, fadsr);
        
        // OSC1
        sp_oscmorph_create(&oscmorph1);
        sp_oscmorph_init(kernel->sp, oscmorph1, kernel->ft_array, AKS1_NUM_FTABLES, 0);
        oscmorph1->freq = 0;
        oscmorph1->amp = 0;
        oscmorph1->wtpos = 0;
        
        // OSC2
        sp_oscmorph_create(&oscmorph2);
        sp_oscmorph_init(kernel->sp, oscmorph2, kernel->ft_array, AKS1_NUM_FTABLES, 0);
        oscmorph2->freq = 0;
        oscmorph2->amp = 0;
        oscmorph2->wtpos = 0;
        
        // CROSSFADE OSC1 and OSC2
        sp_crossfade_create(&morphCrossFade);
        sp_crossfade_init(kernel->sp, morphCrossFade);
        
        // CROSSFADE DRY AND FILTER
        sp_crossfade_create(&filterCrossFade);
        sp_crossfade_init(kernel->sp, filterCrossFade);
        
        // SUB OSC
        sp_osc_create(&subOsc);
        sp_osc_init(kernel->sp, subOsc, kernel->sine, 0.f);
        
        // FM osc
        sp_fosc_create(&fmOsc);
        sp_fosc_init(kernel->sp, fmOsc, kernel->sine);
        
        // NOISE
        sp_noise_create(&noise);
        sp_noise_init(kernel->sp, noise);
        
        // FILTER
        sp_moogladder_create(&loPass);
        sp_moogladder_init(kernel->sp, loPass);
        sp_butbp_create(&bandPass);
        sp_butbp_init(kernel->sp, bandPass);
        sp_buthp_create(&hiPass);
        sp_buthp_init(kernel->sp, hiPass);
    }
    
    void destroy() {
        sp_adsr_destroy(&adsr);
        sp_adsr_destroy(&fadsr);
        sp_oscmorph_destroy(&oscmorph1);
        sp_oscmorph_destroy(&oscmorph2);
        sp_crossfade_destroy(&morphCrossFade);
        sp_crossfade_destroy(&filterCrossFade);
        sp_osc_destroy(&subOsc);
        sp_fosc_destroy(&fmOsc);
        sp_noise_destroy(&noise);
        sp_moogladder_destroy(&loPass);
        sp_butbp_destroy(&bandPass);
        sp_buthp_destroy(&hiPass);
    }
    
    void clear() {
        internalGate = 0;
        stage = stageOff;
        amp = 0;
        rootNoteNumber = -1;
    }
    
    // helper...supports initialization of playing note for both mono and poly
    void startNoteHelper(int noteNumber, int velocity, float frequency) {
        oscmorph1->freq = frequency;
        oscmorph2->freq = frequency;
        subOsc->freq = frequency;
        fmOsc->freq = frequency;
        
        const float amplitude = (float)pow2(velocity / 127.f);
        oscmorph1->amp = amplitude;
        oscmorph2->amp = amplitude;
        subOsc->amp = amplitude;
        fmOsc->amp = amplitude;
        noise->amp = amplitude;
        
        stage = NoteState::stageOn;
        internalGate = 1;
        rootNoteNumber = noteNumber;
    }
    
    //MARK:NoteState.run()
    //called at SampleRate for each NoteState.  Polyphony of 6 = 264,000 times per second
    void run(int frameIndex, float *outL, float *outR) {
        
        // isMono
        const bool isMonoMode = getParam(isMono) > 0.f;
        
        // convenience
        const float lfo1_0_1 = kernel->lfo1_0_1;
        const float lfo1_1_0 = kernel->lfo1_1_0;
        const float lfo2_0_1 = kernel->lfo2_0_1;
        const float lfo2_1_0 = kernel->lfo2_1_0;
        const float lfo3_0_1 = kernel->lfo3_0_1;
        const float lfo3_1_0 = kernel->lfo3_1_0;
        
        //pitchLFO common frequency coefficient
        float commonFrequencyCoefficient = 1.f;
        const float semitone = 0.0594630944f; // 1 = 2^(1/12)
        if (getParam(pitchLFO) == 1.f)
            commonFrequencyCoefficient = 1.f + lfo1_0_1 * semitone;
        else if (getParam(pitchLFO) == 2.f)
            commonFrequencyCoefficient = 1.f + lfo2_0_1 * semitone;
        else if (getParam(pitchLFO) == 3.f)
            commonFrequencyCoefficient = 1.f + lfo3_0_1 * semitone;

        //OSC1 frequency
        const float cachedFrequencyOsc1 = oscmorph1->freq;
        float newFrequencyOsc1 = isMonoMode ?kernel->monoFrequencySmooth :cachedFrequencyOsc1;
        newFrequencyOsc1 *= nnToHz((int)getParam(morph1SemitoneOffset));
        newFrequencyOsc1 *= getParam(detuningMultiplier) * commonFrequencyCoefficient;
        newFrequencyOsc1 = clamp(newFrequencyOsc1, 0.f, 0.5f*AKS1_SAMPLE_RATE);
        oscmorph1->freq = newFrequencyOsc1;
        
        //OSC1: wavetable
        oscmorph1->wtpos = getParam(index1);
        
        //OSC2 frequency
        const float cachedFrequencyOsc2 = oscmorph2->freq;
        float newFrequencyOsc2 = isMonoMode ?kernel->monoFrequencySmooth :cachedFrequencyOsc2;
        newFrequencyOsc2 *= nnToHz((int)getParam(morph2SemitoneOffset));
        newFrequencyOsc2 *= getParam(detuningMultiplier) * commonFrequencyCoefficient;
        
        //LFO DETUNE OSC2
        const float magicDetune = cachedFrequencyOsc2/261.6255653006f;
        if (getParam(detuneLFO) == 1.f)
            newFrequencyOsc2 += lfo1_0_1 * getParam(morph2Detuning) * magicDetune;
        else if (getParam(detuneLFO) == 2.f)
            newFrequencyOsc2 += lfo2_0_1 * getParam(morph2Detuning) * magicDetune;
        else if (getParam(detuneLFO) == 3.f)
            newFrequencyOsc2 += lfo3_0_1 * getParam(morph2Detuning) * magicDetune;
        else
            newFrequencyOsc2 += getParam(morph2Detuning) * magicDetune;
        newFrequencyOsc2 = clamp(newFrequencyOsc2, 0.f, 0.5f*AKS1_SAMPLE_RATE);
        oscmorph2->freq = newFrequencyOsc2;
        
        //OSC2: wavetable
        oscmorph2->wtpos = getParam(index2);
        
        //SUB OSC FREQ
        const float cachedFrequencySub = subOsc->freq;
        float newFrequencySub = isMonoMode ?kernel->monoFrequencySmooth :cachedFrequencySub;
        newFrequencySub *= getParam(detuningMultiplier) / (2.f * (1.f + getParam(subOctaveDown))) * commonFrequencyCoefficient;
        newFrequencySub = clamp(newFrequencySub, 0.f, 0.5f * AKS1_SAMPLE_RATE);
        subOsc->freq = newFrequencySub;
        
        //FM OSC FREQ
        const float cachedFrequencyFM = fmOsc->freq;
        float newFrequencyFM = isMonoMode ?kernel->monoFrequencySmooth :cachedFrequencyFM;
        newFrequencyFM *= getParam(detuningMultiplier) * commonFrequencyCoefficient;
        newFrequencyFM = clamp(newFrequencyFM, 0.f, 0.5f * AKS1_SAMPLE_RATE);
        fmOsc->freq = newFrequencyFM;
        
        //FM LFO
        float fmOscIndx = getParam(fmAmount);
        if (getParam(fmLFO) == 1.f)
            fmOscIndx = getParam(fmAmount) * lfo1_1_0;
        else if (getParam(fmLFO) == 2.f)
            fmOscIndx = getParam(fmAmount) * lfo2_1_0;
        else if (getParam(fmLFO) == 3.f)
            fmOscIndx = getParam(fmAmount) * lfo3_1_0;
        fmOscIndx = kernel->parameterClamp(fmAmount, fmOscIndx);
        fmOsc->indx = fmOscIndx;
        
        //ADSR
        adsr->atk = getParam(attackDuration);
        adsr->rel = getParam(releaseDuration);
        
        //ADSR decay LFO
        float dec = getParam(decayDuration);
        if (getParam(decayLFO) == 1.f)
            dec *= lfo1_1_0;
        else if (getParam(decayLFO) == 2.f)
            dec *= lfo2_1_0;
        else if (getParam(decayLFO) == 3.f)
            dec *= lfo3_1_0;
        dec = kernel->parameterClamp(decayDuration, dec);
        adsr->dec = dec;
        
        //ADSR sustain LFO
        float sus = getParam(sustainLevel);
        adsr->sus = sus;
        
        //FILTER FREQ CUTOFF ADSR
        fadsr->atk = getParam(filterAttackDuration);
        fadsr->dec = getParam(filterDecayDuration);
        fadsr->sus = getParam(filterSustainLevel);
        fadsr->rel = getParam(filterReleaseDuration);
        
        //OSCMORPH CROSSFADE
        float crossFadePos = getParam(morphBalance);
        if (getParam(oscMixLFO) == 1.f)
            crossFadePos = getParam(morphBalance) + lfo1_0_1;
        else if (getParam(oscMixLFO) == 2.f)
            crossFadePos = getParam(morphBalance) + lfo2_0_1;
        else if (getParam(oscMixLFO) == 3.f)
            crossFadePos = getParam(morphBalance) + lfo3_0_1;
        crossFadePos = clamp(crossFadePos, 0.f, 1.f);
        morphCrossFade->pos = crossFadePos;
        
        //TODO:param filterMix is hard-coded to 1.  I vote we get rid of it
        filterCrossFade->pos = getParam(filterMix);
        
        //FILTER RESONANCE LFO
        float filterResonance = getParam(resonance);
        if (getParam(resonanceLFO) == 1)
            filterResonance *= lfo1_1_0;
        else if (getParam(resonanceLFO) == 2)
            filterResonance *= lfo2_1_0;
        else if (getParam(resonanceLFO) == 3)
            filterResonance *= lfo3_1_0;
        filterResonance = kernel->parameterClamp(resonance, filterResonance);
        if (getParam(filterType) == 0) {
            loPass->res = filterResonance;
        } else if (getParam(filterType) == 1) {
            // bandpass bandwidth is a different unit than lopass resonance.
            // take advantage of the range of resonance [0,1].
            const float bandwidth = 0.0625f * AKS1_SAMPLE_RATE * (-1.f + exp2( clamp(1.f - filterResonance, 0.f, 1.f) ) );
            bandPass->bw = bandwidth;
        }
        
        //FINAL OUTs
        float oscmorph1_out = 0.f;
        float oscmorph2_out = 0.f;
        float osc_morph_out = 0.f;
        float subOsc_out = 0.f;
        float fmOsc_out = 0.f;
        float noise_out = 0.f;
        float filterOut = 0.f;
        float finalOut = 0.f;
        
        // osc amp adsr
        sp_adsr_compute(kernel->sp, adsr, &internalGate, &amp);
        
        // filter cutoff adsr
        sp_adsr_compute(kernel->sp, fadsr, &internalGate, &filter);
        
        // filter frequency cutoff calculation
        float filterCutoffFreq = getParam(cutoff);
        if (getParam(cutoffLFO) == 1.f)
            filterCutoffFreq *= lfo1_1_0;
        else if (getParam(cutoffLFO) == 2.f)
            filterCutoffFreq *= lfo2_1_0;
        else if (getParam(cutoffLFO) == 3.f)
            filterCutoffFreq *= lfo3_1_0;

        // filter frequency env lfo crossfade
        float filterEnvLFOMix = getParam(filterADSRMix);
        if (getParam(filterEnvLFO) == 1.f)
            filterEnvLFOMix *= lfo1_1_0;
        else if (getParam(filterEnvLFO) == 2.f)
            filterEnvLFOMix *= lfo2_1_0;
        else if (getParam(filterEnvLFO) == 3.f)
            filterEnvLFOMix *= lfo3_1_0;

        // filter frequency mixer
        filterCutoffFreq -= filterCutoffFreq * filterEnvLFOMix * (1.f - filter);
        filterCutoffFreq = kernel->parameterClamp(cutoff, filterCutoffFreq);
        loPass->freq = filterCutoffFreq;
        bandPass->freq = filterCutoffFreq;
        hiPass->freq = filterCutoffFreq;
        
        //oscmorph1_out
        sp_oscmorph_compute(kernel->sp, oscmorph1, nil, &oscmorph1_out);
        oscmorph1_out *= getParam(morph1Volume);
        
        //oscmorph2_out
        sp_oscmorph_compute(kernel->sp, oscmorph2, nil, &oscmorph2_out);
        oscmorph2_out *= getParam(morph2Volume);
        
        //osc_morph_out
        sp_crossfade_compute(kernel->sp, morphCrossFade, &oscmorph1_out, &oscmorph2_out, &osc_morph_out);
        
        //subOsc_out
        sp_osc_compute(kernel->sp, subOsc, nil, &subOsc_out);
        if (getParam(subIsSquare)) {
            if (subOsc_out > 0.f) {
                subOsc_out = getParam(subVolume);
            } else {
                subOsc_out = -getParam(subVolume);
            }
        } else {
            // make sine louder
            subOsc_out *= getParam(subVolume) * 3.f;
        }
        
        //fmOsc_out
        sp_fosc_compute(kernel->sp, fmOsc, nil, &fmOsc_out);
        fmOsc_out *= getParam(fmVolume);
        
        //noise_out
        sp_noise_compute(kernel->sp, noise, nil, &noise_out);
        noise_out *= getParam(noiseVolume);
        if (getParam(noiseLFO) == 1.f)
            noise_out *= lfo1_1_0;
        else if (getParam(noiseLFO) == 2.f)
            noise_out *= lfo2_1_0;
        else if (getParam(noiseLFO) == 3.f)
            noise_out *= lfo3_1_0;

        //synthOut
        float synthOut = amp * (osc_morph_out + subOsc_out + fmOsc_out + noise_out);
        
        //filterOut
        if (getParam(filterType) == 0.f)
            sp_moogladder_compute(kernel->sp, loPass, &synthOut, &filterOut);
        else if (getParam(filterType) == 1.f)
            sp_butbp_compute(kernel->sp, bandPass, &synthOut, &filterOut);
        else if (getParam(filterType) == 2.f)
            sp_buthp_compute(kernel->sp, hiPass, &synthOut, &filterOut);
        
        // filter crossfade
        sp_crossfade_compute(kernel->sp, filterCrossFade, &synthOut, &filterOut, &finalOut);
        
        // final output
        outL[frameIndex] += finalOut;
        outR[frameIndex] += finalOut;
        
        // restore cached values
        oscmorph1->freq = cachedFrequencyOsc1;
        oscmorph2->freq = cachedFrequencyOsc2;
        subOsc->freq = cachedFrequencySub;
        fmOsc->freq = cachedFrequencyFM;
    }
};

// MARK: AKSynthOneDSPKernel Member Functions

AKSynthOneDSPKernel::AKSynthOneDSPKernel() {}

AKSynthOneDSPKernel::~AKSynthOneDSPKernel() = default;


///panic...hard-resets DSP.  artifacts.
void AKSynthOneDSPKernel::resetDSP() {
    [heldNoteNumbers removeAllObjects];
    [heldNoteNumbersAE updateWithContentsOfArray:heldNoteNumbers];
    arpSeqLastNotes.clear();
    arpSeqNotes.clear();
    arpSeqNotes2.clear();
    arpBeatCounter = 0;
    _setAK1Parameter(arpIsOn, 0.f);
    monoNote->clear();
    for(int i =0; i < AKS1_MAX_POLYPHONY; i++)
        noteStates[i].clear();
    
    print_debug();
}


///puts all notes in release mode...no artifacts
void AKSynthOneDSPKernel::stopAllNotes() {
    [heldNoteNumbers removeAllObjects];
    [heldNoteNumbersAE updateWithContentsOfArray:heldNoteNumbers];
    if (getAK1Parameter(isMono) > 0.f) {
        stopNote(60);
    } else {
        for(int i=0; i<AKS1_NUM_MIDI_NOTES; i++)
            stopNote(i);
    }
    print_debug();
}

//TODO:set aks1 param arpRate
void AKSynthOneDSPKernel::handleTempoSetting(float currentTempo) {
    if (currentTempo != tempo) {
        tempo = currentTempo;
    }
}

//
void AKSynthOneDSPKernel::dependentParameterDidChange(DependentParam param) {
    const BOOL status =
    AEMessageQueuePerformSelectorOnMainThread(audioUnit->_messageQueue,
                                              audioUnit,
                                              @selector(dependentParamDidChange:),
                                              AEArgumentStruct(param),
                                              AEArgumentNone);
    if (!status) {
#if AKS1_DEBUG_DSP_LOGGING
        printf("AKSynthOneDSPKernel::dependentParameterDidChange: AEMessageQueuePerformSelectorOnMainThread FAILED!\n");
#endif
    }
}

///can be called from within the render loop
void AKSynthOneDSPKernel::beatCounterDidChange() {
    AKS1ArpBeatCounter retVal = {arpBeatCounter, heldNoteNumbersAE.count};
    const BOOL status =
    AEMessageQueuePerformSelectorOnMainThread(audioUnit->_messageQueue,
                                              audioUnit,
                                              @selector(arpBeatCounterDidChange:),
                                              AEArgumentStruct(retVal),
                                              AEArgumentNone);
    if (!status) {
#if AKS1_DEBUG_DSP_LOGGING
        printf("AKSynthOneDSPKernel::beatCounterDidChange: AEMessageQueuePerformSelectorOnMainThread FAILED!\n");
#endif
    }
}

///can be called from within the render loop
void AKSynthOneDSPKernel::playingNotesDidChange() {
    
    if (getAK1Parameter(isMono) > 0.f) {
        aePlayingNotes.playingNotes[0] = {monoNote->rootNoteNumber};
        for(int i=1; i<AKS1_MAX_POLYPHONY; i++) {
            aePlayingNotes.playingNotes[i] = {-1};
        }
    } else {
        for(int i=0; i<AKS1_MAX_POLYPHONY; i++) {
            aePlayingNotes.playingNotes[i] = {noteStates[i].rootNoteNumber};
        }
    }
    
    const BOOL status =
    AEMessageQueuePerformSelectorOnMainThread(audioUnit->_messageQueue,
                                              audioUnit,
                                              @selector(playingNotesDidChange:),
                                              AEArgumentStruct(aePlayingNotes),
                                              AEArgumentNone);
    if (!status) {
#if AKS1_DEBUG_DSP_LOGGING
        printf("AKSynthOneDSPKernel::playingNotesDidChange: AEMessageQueuePerformSelectorOnMainThread FAILED!\n");
#endif
    }
}

///can be called from within the render loop
void AKSynthOneDSPKernel::heldNotesDidChange() {
    
    for(int i = 0; i<AKS1_NUM_MIDI_NOTES; i++)
        aeHeldNotes.heldNotes[i] = false;
    
    int count = 0;
    AEArrayEnumeratePointers(heldNoteNumbersAE, NoteNumber *, note) {
        const int nn = note->noteNumber;
        aeHeldNotes.heldNotes[nn] = true;
        ++count;
    }
    aeHeldNotes.heldNotesCount = count;
    
    const BOOL status =
    AEMessageQueuePerformSelectorOnMainThread(audioUnit->_messageQueue,
                                              audioUnit,
                                              @selector(heldNotesDidChange:),
                                              AEArgumentStruct(aeHeldNotes),
                                              AEArgumentNone);
    if (!status) {
#if AKS1_DEBUG_DSP_LOGGING
        printf("AKSynthOneDSPKernel::heldNotesDidChange: AEMessageQueuePerformSelectorOnMainThread FAILED!\n");
#endif
    }
}

//MARK: PROCESS
void AKSynthOneDSPKernel::process(AUAudioFrameCount frameCount, AUAudioFrameCount bufferOffset) {
    initializeNoteStates();
    
    // PREPARE FOR RENDER LOOP...updates here happen at (typically) 44100/512 HZ
    float* outL = (float*)outBufferListPtr->mBuffers[0].mData + bufferOffset;
    float* outR = (float*)outBufferListPtr->mBuffers[1].mData + bufferOffset;
    
    // currently UI is visible in DEV panel only so can't be portamento
    *compressorMasterL->ratio = getAK1Parameter(compressorMasterRatio);
    *compressorMasterR->ratio = getAK1Parameter(compressorMasterRatio);
    *compressorReverbInputL->ratio = getAK1Parameter(compressorReverbInputRatio);
    *compressorReverbInputR->ratio = getAK1Parameter(compressorReverbInputRatio);
    *compressorReverbWetL->ratio = getAK1Parameter(compressorReverbWetRatio);
    *compressorReverbWetR->ratio = getAK1Parameter(compressorReverbWetRatio);
    *compressorMasterL->thresh = getAK1Parameter(compressorMasterThreshold);
    *compressorMasterR->thresh = getAK1Parameter(compressorMasterThreshold);
    *compressorReverbInputL->thresh = getAK1Parameter(compressorReverbInputThreshold);
    *compressorReverbInputR->thresh = getAK1Parameter(compressorReverbInputThreshold);
    *compressorReverbWetL->thresh = getAK1Parameter(compressorReverbWetThreshold);
    *compressorReverbWetR->thresh = getAK1Parameter(compressorReverbWetThreshold);
    *compressorMasterL->atk = getAK1Parameter(compressorMasterAttack);
    *compressorMasterR->atk = getAK1Parameter(compressorMasterAttack);
    *compressorReverbInputL->atk = getAK1Parameter(compressorReverbInputAttack);
    *compressorReverbInputR->atk = getAK1Parameter(compressorReverbInputAttack);
    *compressorReverbWetL->atk = getAK1Parameter(compressorReverbWetAttack);
    *compressorReverbWetR->atk = getAK1Parameter(compressorReverbWetAttack);
    *compressorMasterL->rel = getAK1Parameter(compressorMasterRelease);
    *compressorMasterR->rel = getAK1Parameter(compressorMasterRelease);
    *compressorReverbInputL->rel = getAK1Parameter(compressorReverbInputRelease);
    *compressorReverbInputR->rel = getAK1Parameter(compressorReverbInputRelease);
    *compressorReverbWetL->rel = getAK1Parameter(compressorReverbWetRelease);
    *compressorReverbWetR->rel = getAK1Parameter(compressorReverbWetRelease);
    
    // transition playing notes from release to off
    bool transitionedToOff = false;
    if (getAK1Parameter(isMono) > 0.f) {
        if (monoNote->stage == NoteState::stageRelease && monoNote->amp <= AKS1_RELEASE_AMPLITUDE_THRESHOLD) {
            monoNote->clear();
            transitionedToOff = true;
        }
    } else {
        for(int i=0; i<polyphony; i++) {
            NoteState& note = noteStates[i];
            if (note.stage == NoteState::stageRelease && note.amp <= AKS1_RELEASE_AMPLITUDE_THRESHOLD) {
                note.clear();
                transitionedToOff = true;
            }
        }
    }
    if (transitionedToOff)
        playingNotesDidChange();

    const float arpTempo = getAK1Parameter(arpRate);
    const double secPerBeat = 0.5f * 0.5f * 60.f / arpTempo;
    
    // RENDER LOOP: Render one audio frame at sample rate, i.e. 44100 HZ
    for (AUAudioFrameCount frameIndex = 0; frameIndex < frameCount; ++frameIndex) {

        //PORTAMENTO
        for(int i = 0; i< AKSynthOneParameter::AKSynthOneParameterCount; i++) {
            if (aks1p[i].usePortamento) {
                sp_port_compute(sp, aks1p[i].portamento, &aks1p[i].portamentoTarget, &p[i]);
            }
        }
        monoFrequencyPort->htime = getAK1Parameter(glide);
        sp_port_compute(sp, monoFrequencyPort, &monoFrequency, &monoFrequencySmooth);
        
        // CLEAR BUFFER
        outL[frameIndex] = outR[frameIndex] = 0.f;
        
        // Clear all notes when toggling Mono <==> Poly
        if (getAK1Parameter(isMono) != previousProcessMonoPolyStatus ) {
            previousProcessMonoPolyStatus = getAK1Parameter(isMono);
            reset(); // clears all mono and poly notes
            arpSeqLastNotes.clear();
        }
        
        //MARK: ARP/SEQ
        if (getAK1Parameter(arpIsOn) == 1.f || arpSeqLastNotes.size() > 0) {
            const double r0 = fmod(arpTime, secPerBeat);
            arpTime = arpSampleCounter/AKS1_SAMPLE_RATE;
            arpSampleCounter += 1.0;
            const double r1 = fmod(arpTime, secPerBeat);
            if (r1 < r0) {
                // NEW beatCounter
                // turn Off previous beat's notes
                for (std::list<int>::iterator arpLastNotesIterator = arpSeqLastNotes.begin(); arpLastNotesIterator != arpSeqLastNotes.end(); ++arpLastNotesIterator) {
                    turnOffKey(*arpLastNotesIterator);
                }
                arpSeqLastNotes.clear();

                // Create Arp/Seq array based on held notes and/or sequence parameters
                if (getAK1Parameter(arpIsOn) == 1.f && heldNoteNumbersAE.count > 0) {
                    arpSeqNotes.clear();
                    arpSeqNotes2.clear();
                    
                    // only update "notes per octave" when beat counter changes so arpSeqNotes and arpSeqLastNotes match
                    notesPerOctave = (int)AKPolyphonicNode.tuningTable.npo;
                    if (notesPerOctave <= 0) notesPerOctave = 12;
                    const float npof = (float)notesPerOctave/12.f; // 12ET ==> npof = 1
                    
                    // only create arp/sequence if at least one key is held down
                    if (getAK1Parameter(arpIsSequencer) == 1.f) {
                        // SEQUENCER
                        const int numSteps = getAK1Parameter(arpTotalSteps) > 16 ? 16 : (int)getAK1Parameter(arpTotalSteps);
                        for(int i = 0; i < numSteps; i++) {
                            const float onOff = getAK1Parameter((AKSynthOneParameter)(i + arpSeqNoteOn00));
                            const int octBoost = getAK1Parameter((AKSynthOneParameter)(i + arpSeqOctBoost00));
                            const int nn = getAK1Parameter((AKSynthOneParameter)(i + arpSeqPattern00)) * npof;
                            const int nnob = (nn < 0) ? (nn - octBoost * notesPerOctave) : (nn + octBoost * notesPerOctave);
                            struct SeqNoteNumber snn;
                            snn.init(nnob, onOff);
                            arpSeqNotes.push_back(snn);
                        }
                    } else {
                        // ARP state
                        AEArrayEnumeratePointers(heldNoteNumbersAE, NoteNumber *, note) {
                            std::vector<NoteNumber>::iterator it = arpSeqNotes2.begin();
                            arpSeqNotes2.insert(it, *note);
                        }
                        const int heldNotesCount = (int)arpSeqNotes2.size();
                        const int arpIntervalUp = getAK1Parameter(arpInterval) * npof;
                        const int onOff = 1;
                        const int arpOctaves = (int)getAK1Parameter(arpOctave) + 1;
                        
                        if (getAK1Parameter(arpDirection) == 0.f) {
                            // ARP Up
                            int index = 0;
                            for (int octave = 0; octave < arpOctaves; octave++) {
                                for (int i = 0; i < heldNotesCount; i++) {
                                    NoteNumber& note = arpSeqNotes2[i];
                                    const int nn = note.noteNumber + (octave * arpIntervalUp);
                                    struct SeqNoteNumber snn;
                                    snn.init(nn, onOff);
                                    std::vector<SeqNoteNumber>::iterator it = arpSeqNotes.begin() + index;
                                    arpSeqNotes.insert(it, snn);
                                    ++index;
                                }
                            }
                        } else if (getAK1Parameter(arpDirection) == 1.f) {
                            ///ARP Up + Down
                            //up
                            int index = 0;
                            for (int octave = 0; octave < arpOctaves; octave++) {
                                for (int i = 0; i < heldNotesCount; i++) {
                                    NoteNumber& note = arpSeqNotes2[i];
                                    const int nn = note.noteNumber + (octave * arpIntervalUp);
                                    struct SeqNoteNumber snn;
                                    snn.init(nn, onOff);
                                    std::vector<SeqNoteNumber>::iterator it = arpSeqNotes.begin() + index;
                                    arpSeqNotes.insert(it, snn);
                                    ++index;
                                }
                            }
                            //down, minus head and tail
                            for (int octave = arpOctaves - 1; octave >= 0; octave--) {
                                for (int i = heldNotesCount - 1; i >= 0; i--) {
                                    const bool firstNote = (i == heldNotesCount - 1) && (octave == arpOctaves - 1);
                                    const bool lastNote = (i == 0) && (octave == 0);
                                    if (!firstNote && !lastNote) {
                                        NoteNumber& note = arpSeqNotes2[i];
                                        const int nn = note.noteNumber + (octave * arpIntervalUp);
                                        struct SeqNoteNumber snn;
                                        snn.init(nn, onOff);
                                        std::vector<SeqNoteNumber>::iterator it = arpSeqNotes.begin() + index;
                                        arpSeqNotes.insert(it, snn);
                                        ++index;
                                    }
                                }
                            }
                        } else if (getAK1Parameter(arpDirection) == 2.f) {
                            // ARP Down
                            int index = 0;
                            for (int octave = arpOctaves - 1; octave >= 0; octave--) {
                                for (int i = heldNotesCount - 1; i >= 0; i--) {
                                    NoteNumber& note = arpSeqNotes2[i];
                                    const int nn = note.noteNumber + (octave * arpIntervalUp);
                                    struct SeqNoteNumber snn;
                                    snn.init(nn, onOff);
                                    std::vector<SeqNoteNumber>::iterator it = arpSeqNotes.begin() + index;
                                    arpSeqNotes.insert(it, snn);
                                    ++index;
                                }
                            }
                        }
                    }
                }
                
                // No keys held down
                if (heldNoteNumbersAE.count == 0) {
                    if (arpBeatCounter > 0) {
                        arpBeatCounter = 0;
                        beatCounterDidChange();
                    }
                } else if (arpSeqNotes.size() == 0) {
                    // NOP for zero-length arp/seq
                } else {
                    // Advance arp/seq beatCounter, notify delegates
                    const int seqNotePosition = arpBeatCounter % arpSeqNotes.size();
                    ++arpBeatCounter;
                    beatCounterDidChange();
                    
                    // Play the arp/seq
                    if (getAK1Parameter(arpIsOn) > 0.f) {
                        // ARP+SEQ: turnOn the note of the sequence
                        SeqNoteNumber& snn = arpSeqNotes[seqNotePosition];
                        if (getAK1Parameter(arpIsSequencer) == 1.f) {
                            // SEQUENCER
                            if (snn.onOff == 1) {
                                AEArrayEnumeratePointers(heldNoteNumbersAE, NoteNumber *, noteStruct) {
                                    const int baseNote = noteStruct->noteNumber;
                                    const int note = baseNote + snn.noteNumber;
                                    if (note >= 0 && note < AKS1_NUM_MIDI_NOTES) {
                                        turnOnKey(note, 127);
                                        arpSeqLastNotes.push_back(note);
                                    }
                                }
                            }
                        } else {
                            // ARPEGGIATOR
                            const int note = snn.noteNumber;
                            if (note >= 0 && note < AKS1_NUM_MIDI_NOTES) {
                                turnOnKey(note, 127);
                                arpSeqLastNotes.push_back(note);
                            }
                        }
                    }
                }
            }
        }
        
        //LFO1 on [-1, 1]
        lfo1Phasor->freq = getAK1Parameter(lfo1Rate);
        sp_phasor_compute(sp, lfo1Phasor, nil, &lfo1); // sp_phasor_compute [0,1]
        if (getAK1Parameter(lfo1Index) == 0) { // Sine
            lfo1 = sin(lfo1 * M_PI * 2.f);
        } else if (getAK1Parameter(lfo1Index) == 1) { // Square
            if (lfo1 > 0.5f) {
                lfo1 = 1.f;
            } else {
                lfo1 = -1.f;
            }
        } else if (getAK1Parameter(lfo1Index) == 2) { // Saw
            lfo1 = (lfo1 - 0.5f) * 2.f;
        } else if (getAK1Parameter(lfo1Index) == 3) { // Reversed Saw
            lfo1 = (0.5f - lfo1) * 2.f;
        }
        lfo1_0_1 = 0.5f * (1.f + lfo1) * getAK1Parameter(lfo1Amplitude);
        lfo1_1_0 = 1.f - lfo1_0_1; // good for multiplicative

        //LFO2 on [-1, 1]
        lfo2Phasor->freq = getAK1Parameter(lfo2Rate);
        sp_phasor_compute(sp, lfo2Phasor, nil, &lfo2);  // sp_phasor_compute [0,1]
        if (getAK1Parameter(lfo2Index) == 0) { // Sine
            lfo2 = sin(lfo2 * M_PI * 2.0);
        } else if (getAK1Parameter(lfo2Index) == 1) { // Square
            if (lfo2 > 0.5f) {
                lfo2 = 1.f;
            } else {
                lfo2 = -1.f;
            }
        } else if (getAK1Parameter(lfo2Index) == 2) { // Saw
            lfo2 = (lfo2 - 0.5f) * 2.f;
        } else if (getAK1Parameter(lfo2Index) == 3) { // Reversed Saw
            lfo2 = (0.5f - lfo2) * 2.f;
        }
        lfo2_0_1 = 0.5f * (1.f + lfo2) * getAK1Parameter(lfo2Amplitude);
        lfo2_1_0 = 1.f - lfo2_0_1;
        lfo3_0_1 = 0.5f * (lfo1_0_1 + lfo2_0_1);
        lfo3_1_0 = 1.f - lfo3_0_1;

        // RENDER NoteState into (outL, outR)
        if (getAK1Parameter(isMono) > 0.f) {
            if (monoNote->rootNoteNumber != -1 && monoNote->stage != NoteState::stageOff)
                monoNote->run(frameIndex, outL, outR);
        } else {
            for(int i=0; i<polyphony; i++) {
                NoteState& note = noteStates[i];
                if (note.rootNoteNumber != -1 && note.stage != NoteState::stageOff)
                    note.run(frameIndex, outL, outR);
            }
        }
        
        // NoteState render output "synthOut" is mono
        float synthOut = outL[frameIndex];
        
        // BITCRUSH LFO
        float bitcrushSrate = getAK1Parameter(bitCrushSampleRate);
        bitcrushSrate = log2(bitcrushSrate);
        const float magicNumber = 4.f;
        if (getAK1Parameter(bitcrushLFO) == 1.f)
            bitcrushSrate += magicNumber * lfo1_0_1;
        else if (getAK1Parameter(bitcrushLFO) == 2.f)
            bitcrushSrate += magicNumber * lfo2_0_1;
        else if (getAK1Parameter(bitcrushLFO) == 3.f)
            bitcrushSrate += magicNumber * lfo3_0_1;
        bitcrushSrate = exp2(bitcrushSrate);
        bitcrushSrate = parameterClamp(bitCrushSampleRate, bitcrushSrate); // clamp
        
        //BITCRUSH
        float bitCrushOut = synthOut;
        bitcrushIncr = AKS1_SAMPLE_RATE / bitcrushSrate; //TODO:use live sample rate, not hard-coded
        if (bitcrushIncr < 1.f) bitcrushIncr = 1.f; // for the case where the audio engine samplerate > 44100 (i.e., 48000)
        if (bitcrushIndex <= bitcrushSampleIndex) {
            bitCrushOut = bitcrushValue = synthOut;
            bitcrushIndex += bitcrushIncr; // bitcrushIncr >= 1
            bitcrushIndex -= bitcrushSampleIndex;
            bitcrushSampleIndex = 0;
        } else {
            bitCrushOut = bitcrushValue;
        }
        bitcrushSampleIndex += 1.f;
        
        //TREMOLO
        if (getAK1Parameter(tremoloLFO) == 1.f)
            bitCrushOut *= lfo1_1_0;
        else if (getAK1Parameter(tremoloLFO) == 2.f)
            bitCrushOut *= lfo2_1_0;
        else if (getAK1Parameter(tremoloLFO) == 3.f)
            bitCrushOut *= lfo3_1_0;
        
        // signal goes from mono to stereo with autopan
        
        //AUTOPAN
        panOscillator->freq = getAK1Parameter(autoPanFrequency);
        panOscillator->amp = getAK1Parameter(autoPanAmount);
        float panValue = 0.f;
        sp_osc_compute(sp, panOscillator, nil, &panValue);
        pan->pan = panValue;
        float panL = 0.f, panR = 0.f;
        sp_pan2_compute(sp, pan, &bitCrushOut, &panL, &panR);
        
        // PHASER+CROSSFADE
        float phaserOutL = panL;
        float phaserOutR = panR;
        float lPhaserMix = getAK1Parameter(phaserMix);
        *phaser0->Notch_width = getAK1Parameter(phaserNotchWidth);
        *phaser0->feedback_gain = getAK1Parameter(phaserFeedback);
        *phaser0->lfobpm = getAK1Parameter(phaserRate);
        if (lPhaserMix != 0.f) {
            lPhaserMix = 1.f - lPhaserMix;
            sp_phaser_compute(sp, phaser0, &panL, &panR, &phaserOutL, &phaserOutR);
            phaserOutL = lPhaserMix * panL + (1.f - lPhaserMix) * phaserOutL;
            phaserOutR = lPhaserMix * panR + (1.f - lPhaserMix) * phaserOutR;
        }
        
        // DELAY INPUT LOW PASS FILTER
        //linear interpolation of percentage in pitch space
        const float pmin2 = log2(1024.f);
        const float pmax2 = log2(parameterMax(cutoff));
        const float pval1 = getAK1Parameter(cutoff);
        float pval2 = log2(pval1);
        if (pval2 < pmin2) pval2 = pmin2;
        if (pval2 > pmax2) pval2 = pmax2;
        const float pnorm2 = (pval2 - pmin2)/(pmax2 - pmin2);
        const float mmax = getAK1Parameter(delayInputCutoffTrackingRatio);
        const float mmin = 1.f;
        const float oscFilterFreqCutoffPercentage = mmin + pnorm2 * (mmax - mmin);
        const float oscFilterResonance = 0.f; // constant
        float oscFilterFreqCutoff = pval1 * oscFilterFreqCutoffPercentage;
        oscFilterFreqCutoff = parameterClamp(cutoff, oscFilterFreqCutoff);
        loPassInputDelayL->freq = oscFilterFreqCutoff;
        loPassInputDelayL->res = oscFilterResonance;
        loPassInputDelayR->freq = oscFilterFreqCutoff;
        loPassInputDelayR->res = oscFilterResonance;
        float delayInputLowPassOutL = phaserOutL;
        float delayInputLowPassOutR = phaserOutR;
        sp_moogladder_compute(sp, loPassInputDelayL, &phaserOutL, &delayInputLowPassOutL);
        sp_moogladder_compute(sp, loPassInputDelayR, &phaserOutR, &delayInputLowPassOutR);

        // PING PONG DELAY
        float delayOutL = 0.f;
        float delayOutR = 0.f;
        float delayOutRR = 0.f;
        float delayFillInOut = 0.f;
        delayL->del = delayR->del = getAK1Parameter(delayTime) * 2.f;
        delayRR->del = delayFillIn->del = getAK1Parameter(delayTime);
        delayL->feedback = delayR->feedback = getAK1Parameter(delayFeedback);
        delayRR->feedback = delayFillIn->feedback = getAK1Parameter(delayFeedback);
        sp_vdelay_compute(sp, delayL,      &delayInputLowPassOutL, &delayOutL);
        sp_vdelay_compute(sp, delayR,      &delayInputLowPassOutR, &delayOutR);
        sp_vdelay_compute(sp, delayFillIn, &delayInputLowPassOutR, &delayFillInOut);
        sp_vdelay_compute(sp, delayRR,     &delayOutR,  &delayOutRR);
        delayOutRR += delayFillInOut;
        
        // DELAY MIXER
        float mixedDelayL = 0.f;
        float mixedDelayR = 0.f;
        delayCrossfadeL->pos = getAK1Parameter(delayMix) * getAK1Parameter(delayOn);
        delayCrossfadeR->pos = getAK1Parameter(delayMix) * getAK1Parameter(delayOn);
        sp_crossfade_compute(sp, delayCrossfadeL, &phaserOutL, &delayOutL, &mixedDelayL);
        sp_crossfade_compute(sp, delayCrossfadeR, &phaserOutR, &delayOutRR, &mixedDelayR);
        
        // REVERB INPUT HIPASS FILTER
        float butOutL = 0.f;
        float butOutR = 0.f;
        butterworthHipassL->freq = getAK1Parameter(reverbHighPass);
        butterworthHipassR->freq = getAK1Parameter(reverbHighPass);
        sp_buthp_compute(sp, butterworthHipassL, &mixedDelayL, &butOutL);
        sp_buthp_compute(sp, butterworthHipassR, &mixedDelayR, &butOutR);

        // Pre Gain + compression on reverb input
        butOutL *= 2.f;
        butOutR *= 2.f;
        float butCompressOutL = 0.f;
        float butCompressOutR = 0.f;
        sp_compressor_compute(sp, compressorReverbInputL, &butOutL, &butCompressOutL);
        sp_compressor_compute(sp, compressorReverbInputR, &butOutR, &butCompressOutR);
        butCompressOutL *= getAK1Parameter(compressorReverbInputMakeupGain);
        butCompressOutR *= getAK1Parameter(compressorReverbInputMakeupGain);

        // REVERB
        float reverbWetL = 0.f;
        float reverbWetR = 0.f;
        reverbCostello->feedback = getAK1Parameter(reverbFeedback);
        reverbCostello->lpfreq = 0.5f * AKS1_SAMPLE_RATE;
        sp_revsc_compute(sp, reverbCostello, &butCompressOutL, &butCompressOutR, &reverbWetL, &reverbWetR);
        
        // compressor for wet reverb; like X2, FM
        float wetReverbLimiterL = reverbWetL;
        float wetReverbLimiterR = reverbWetR;
        sp_compressor_compute(sp, compressorReverbWetL, &reverbWetL, &wetReverbLimiterL);
        sp_compressor_compute(sp, compressorReverbWetR, &reverbWetR, &wetReverbLimiterR);
        wetReverbLimiterL *= getAK1Parameter(compressorReverbWetMakeupGain);
        wetReverbLimiterR *= getAK1Parameter(compressorReverbWetMakeupGain);
        
        // crossfade wet reverb with wet+dry delay
        float reverbCrossfadeOutL = 0.f;
        float reverbCrossfadeOutR = 0.f;
        float reverbMixFactor = getAK1Parameter(reverbMix) * getAK1Parameter(reverbOn);
        if (getAK1Parameter(reverbMixLFO) == 1.f)
            reverbMixFactor *= lfo1_1_0;
        else if (getAK1Parameter(reverbMixLFO) == 2.f)
            reverbMixFactor *= lfo2_1_0;
        else if (getAK1Parameter(reverbMixLFO) == 3.f)
            reverbMixFactor *= lfo3_1_0;
        revCrossfadeL->pos = reverbMixFactor;
        revCrossfadeR->pos = reverbMixFactor;
        sp_crossfade_compute(sp, revCrossfadeL, &mixedDelayL, &wetReverbLimiterL, &reverbCrossfadeOutL);
        sp_crossfade_compute(sp, revCrossfadeR, &mixedDelayR, &wetReverbLimiterR, &reverbCrossfadeOutR);
        
        // MASTER COMPRESSOR/LIMITER
        // 3db pre gain on input to master compressor
        reverbCrossfadeOutL *= (2.f * getAK1Parameter(masterVolume));
        reverbCrossfadeOutR *= (2.f * getAK1Parameter(masterVolume));
        float compressorOutL = reverbCrossfadeOutL;
        float compressorOutR = reverbCrossfadeOutR;
        
        // MASTER COMPRESSOR TOGGLE: 0 = no compressor, 1 = compressor
        sp_compressor_compute(sp, compressorMasterL, &reverbCrossfadeOutL, &compressorOutL);
        sp_compressor_compute(sp, compressorMasterR, &reverbCrossfadeOutR, &compressorOutR);

        // Makeup Gain on Master Compressor
        compressorOutL *= getAK1Parameter(compressorMasterMakeupGain);
        compressorOutR *= getAK1Parameter(compressorMasterMakeupGain);

        // WIDEN: constant delay with no filtering, so functionally equivalent to being inside master
        float widenOutR = 0.f;
        sp_delay_compute(sp, widenDelay, &compressorOutR, &widenOutR);
        widenOutR = getAK1Parameter(widen) * widenOutR + (1.f - getAK1Parameter(widen)) * compressorOutR;

        // MASTER
        outL[frameIndex] = compressorOutL;
        outR[frameIndex] = widenOutR;
    }
}

void AKSynthOneDSPKernel::turnOnKey(int noteNumber, int velocity) {
    if (noteNumber < 0 || noteNumber >= AKS1_NUM_MIDI_NOTES)
        return;
    
    const float frequency = tuningTableNoteToHz(noteNumber);
    turnOnKey(noteNumber, velocity, frequency);
}

// turnOnKey is called by render thread in "process", so access note via AEArray
void AKSynthOneDSPKernel::turnOnKey(int noteNumber, int velocity, float frequency) {
    if (noteNumber < 0 || noteNumber >= AKS1_NUM_MIDI_NOTES)
        return;
    initializeNoteStates();
    
    if (getAK1Parameter(isMono) > 0.f) {
        NoteState& note = *monoNote;
        monoFrequency = frequency;
        
        // PORTAMENTO: set the ADSRs to release mode here, then into attack mode inside startNoteHelper
        if (getAK1Parameter(monoIsLegato) == 0) {
            note.internalGate = 0;
            note.stage = NoteState::stageRelease;
            sp_adsr_compute(sp, note.adsr, &note.internalGate, &note.amp);
            sp_adsr_compute(sp, note.fadsr, &note.internalGate, &note.filter);
        }
        
        // legato+portamento: Legato means that Presets with low sustains will sound like they did not retrigger.
        note.startNoteHelper(noteNumber, velocity, frequency);
        
    } else {
        // Note Stealing: Is noteNumber already playing?
        int index = -1;
        for(int i = 0 ; i < polyphony; i++) {
            if (noteStates[i].rootNoteNumber == noteNumber) {
                index = i;
                break;
            }
        }
        if (index != -1) {
            // noteNumber is playing...steal it
            playingNoteStatesIndex = index;
        } else {
            // noteNumber is not playing: search for non-playing notes (-1) starting with current index
            for(int i = 0; i < polyphony; i++) {
                const int modIndex = (playingNoteStatesIndex + i) % polyphony;
                if (noteStates[modIndex].rootNoteNumber == -1) {
                    index = modIndex;
                    break;
                }
            }
            
            if (index == -1) {
                // if there are no non-playing notes then steal oldest note
                ++playingNoteStatesIndex %= polyphony;
            } else {
                // use non-playing note slot
                playingNoteStatesIndex = index;
            }
        }
        
        // POLY: INIT NoteState
        NoteState& note = noteStates[playingNoteStatesIndex];
        note.startNoteHelper(noteNumber, velocity, frequency);
    }
    
    heldNotesDidChange();
    playingNotesDidChange();
}

// turnOffKey is called by render thread in "process", so access note via AEArray
void AKSynthOneDSPKernel::turnOffKey(int noteNumber) {
    if (noteNumber < 0 || noteNumber >= AKS1_NUM_MIDI_NOTES)
        return;
    initializeNoteStates();
    if (getAK1Parameter(isMono) > 0.f) {
        if (getAK1Parameter(arpIsOn) == 1.f || heldNoteNumbersAE.count == 0) {
            // the case where this was the only held note and now it should be off, OR
            // the case where the sequencer turns off this key even though a note is held down
            if (monoNote->stage != NoteState::stageOff) {
                monoNote->stage = NoteState::stageRelease;
                monoNote->internalGate = 0;
            }
        } else {
            // the case where you had more than one held note and released one (CACA): Keep note ON and set to freq of head
            AEArrayToken token = AEArrayGetToken(heldNoteNumbersAE);
            NoteNumber* nn = (NoteNumber*)AEArrayGetItem(token, 0);
            const int headNN = nn->noteNumber;
            monoFrequency = tuningTableNoteToHz(headNN);
            monoNote->rootNoteNumber = headNN;
            monoFrequency = tuningTableNoteToHz(headNN);
            monoNote->oscmorph1->freq = monoFrequency;
            monoNote->oscmorph2->freq = monoFrequency;
            monoNote->subOsc->freq = monoFrequency;
            monoNote->fmOsc->freq = monoFrequency;
            
            // PORTAMENTO: reset the ADSR inside the render loop
            if (getAK1Parameter(monoIsLegato) == 0.f) {
                monoNote->internalGate = 0;
                monoNote->stage = NoteState::stageRelease;
                sp_adsr_compute(sp, monoNote->adsr, &monoNote->internalGate, &monoNote->amp);
                sp_adsr_compute(sp, monoNote->fadsr, &monoNote->internalGate, &monoNote->filter);
            }
            
            // legato+portamento: Legato means that Presets with low sustains will sound like they did not retrigger.
            monoNote->stage = NoteState::stageOn;
            monoNote->internalGate = 1;
        }
    } else {
        // Poly:
        int index = -1;
        for(int i=0; i<polyphony; i++) {
            if (noteStates[i].rootNoteNumber == noteNumber) {
                index = i;
                break;
            }
        }
        
        if (index != -1) {
            // put NoteState into release
            NoteState& note = noteStates[index];
            note.stage = NoteState::stageRelease;
            note.internalGate = 0;
        } else {
            // the case where a note was stolen before the noteOff
        }
    }
    heldNotesDidChange();
    playingNotesDidChange();
}

// NOTE ON
// startNote is not called by render thread, but turnOnKey is
void AKSynthOneDSPKernel::startNote(int noteNumber, int velocity) {
    if (noteNumber < 0 || noteNumber >= AKS1_NUM_MIDI_NOTES)
        return;
    
    const float frequency = tuningTableNoteToHz(noteNumber);
    startNote(noteNumber, velocity, frequency);
}

// NOTE ON
// startNote is not called by render thread, but turnOnKey is
void AKSynthOneDSPKernel::startNote(int noteNumber, int velocity, float frequency) {
    if (noteNumber < 0 || noteNumber >= AKS1_NUM_MIDI_NOTES)
        return;
    
    NSNumber* nn = @(noteNumber);
    [heldNoteNumbers removeObject:nn];
    [heldNoteNumbers insertObject:nn atIndex:0];
    [heldNoteNumbersAE updateWithContentsOfArray:heldNoteNumbers];
    
    // ARP/SEQ
    if (getAK1Parameter(arpIsOn) == 1.f) {
        return;
    } else {
        turnOnKey(noteNumber, velocity, frequency);
    }
}

// NOTE OFF...put into release mode
void AKSynthOneDSPKernel::stopNote(int noteNumber) {
    if (noteNumber < 0 || noteNumber >= AKS1_NUM_MIDI_NOTES)
        return;
    
    NSNumber* nn = @(noteNumber);
    [heldNoteNumbers removeObject: nn];
    [heldNoteNumbersAE updateWithContentsOfArray: heldNoteNumbers];
    
    // ARP/SEQ
    if (getAK1Parameter(arpIsOn) == 1.f)
        return;
    else
        turnOffKey(noteNumber);
}

void AKSynthOneDSPKernel::reset() {
    for (int i = 0; i<AKS1_MAX_POLYPHONY; i++)
        noteStates[i].clear();
    monoNote->clear();
    resetted = true;
}

void AKSynthOneDSPKernel::resetSequencer() {
    arpBeatCounter = 0;
    arpSampleCounter = 0;
    arpTime = 0;
    beatCounterDidChange();
}

// MIDI
void AKSynthOneDSPKernel::handleMIDIEvent(AUMIDIEvent const& midiEvent) {
    if (midiEvent.length != 3) return;
    uint8_t status = midiEvent.data[0] & 0xF0;
    switch (status) {
        case 0x80 : {
            // note off
            uint8_t note = midiEvent.data[1];
            if (note > 127) break;
            stopNote(note);
            break;
        }
        case 0x90 : {
            // note on
            uint8_t note = midiEvent.data[1];
            uint8_t veloc = midiEvent.data[2];
            if (note > 127 || veloc > 127) break;
            startNote(note, veloc);
            break;
        }
        case 0xB0 : {
            uint8_t num = midiEvent.data[1];
            if (num == 123) {
                stopAllNotes();
            }
            break;
        }
    }
}

void AKSynthOneDSPKernel::init(int _channels, double _sampleRate) {
    AKSoundpipeKernel::init(_channels, _sampleRate);
    sp_ftbl_create(sp, &sine, AKS1_FTABLE_SIZE);
    sp_gen_sine(sp, sine);
    sp_phasor_create(&lfo1Phasor);
    sp_phasor_init(sp, lfo1Phasor, 0);
    sp_phasor_create(&lfo2Phasor);
    sp_phasor_init(sp, lfo2Phasor, 0);
    sp_phaser_create(&phaser0);
    sp_phaser_init(sp, phaser0);
    sp_port_create(&monoFrequencyPort);
    sp_port_init(sp, monoFrequencyPort, 0.05f);
    sp_osc_create(&panOscillator);
    sp_osc_init(sp, panOscillator, sine, 0.f);
    sp_pan2_create(&pan);
    sp_pan2_init(sp, pan);
    
    sp_moogladder_create(&loPassInputDelayL);
    sp_moogladder_init(sp, loPassInputDelayL);
    sp_moogladder_create(&loPassInputDelayR);
    sp_moogladder_init(sp, loPassInputDelayR);
    sp_vdelay_create(&delayL);
    sp_vdelay_create(&delayR);
    sp_vdelay_create(&delayRR);
    sp_vdelay_create(&delayFillIn);
    sp_vdelay_init(sp, delayL, 10.f);
    sp_vdelay_init(sp, delayR, 10.f);
    sp_vdelay_init(sp, delayRR, 10.f);
    sp_vdelay_init(sp, delayFillIn, 10.f);
    sp_crossfade_create(&delayCrossfadeL);
    sp_crossfade_create(&delayCrossfadeR);
    sp_crossfade_init(sp, delayCrossfadeL);
    sp_crossfade_init(sp, delayCrossfadeR);
    sp_revsc_create(&reverbCostello);
    sp_revsc_init(sp, reverbCostello);
    sp_buthp_create(&butterworthHipassL);
    sp_buthp_init(sp, butterworthHipassL);
    sp_buthp_create(&butterworthHipassR);
    sp_buthp_init(sp, butterworthHipassR);
    sp_crossfade_create(&revCrossfadeL);
    sp_crossfade_create(&revCrossfadeR);
    sp_crossfade_init(sp, revCrossfadeL);
    sp_crossfade_init(sp, revCrossfadeR);
    sp_compressor_create(&compressorMasterL);
    sp_compressor_init(sp, compressorMasterL);
    sp_compressor_create(&compressorMasterR);
    sp_compressor_init(sp, compressorMasterR);
    sp_compressor_create(&compressorReverbInputL);
    sp_compressor_init(sp, compressorReverbInputL);
    sp_compressor_create(&compressorReverbInputR);
    sp_compressor_init(sp, compressorReverbInputR);
    sp_compressor_create(&compressorReverbWetL);
    sp_compressor_init(sp, compressorReverbWetL);
    sp_compressor_create(&compressorReverbWetR);
    sp_compressor_init(sp, compressorReverbWetR);
    sp_delay_create(&widenDelay);
    sp_delay_init(sp, widenDelay, 0.05f);
    widenDelay->feedback = 0.f;
    noteStates = (NoteState*)malloc(AKS1_MAX_POLYPHONY * sizeof(NoteState));
    monoNote = (NoteState*)malloc(sizeof(NoteState));
    heldNoteNumbers = (NSMutableArray<NSNumber*>*)[NSMutableArray array];
    heldNoteNumbersAE = [[AEArray alloc] initWithCustomMapping:^void *(id item) {
        const int nn = [(NSNumber*)item intValue];
        NoteNumber* noteNumber = (NoteNumber*)malloc(sizeof(NoteNumber));
        noteNumber->noteNumber = nn;
        return noteNumber;
    }];
    
    _rate.init();

    // copy default dsp values
    for(int i = 0; i< AKSynthOneParameter::AKSynthOneParameterCount; i++) {
        const float value = parameterDefault((AKSynthOneParameter)i);
        if (aks1p[i].usePortamento) {
            aks1p[i].portamentoTarget = value;
            sp_port_create(&aks1p[i].portamento);
            sp_port_init(sp, aks1p[i].portamento, value);
            aks1p[i].portamento->htime = AKS1_PORTAMENTO_HALF_TIME;
        }
        p[i] = value;
#if AKS1_DEBUG_DSP_LOGGING
        const char* d = AKSynthOneDSPKernel::parameterCStr((AKSynthOneParameter)i);
        printf("AKSynthOneDSPKernel.hpp:setAK1Parameter(): %i:%s --> %f\n", i, d, value);
#endif
    }
    _lfo1Rate = {AKSynthOneParameter::lfo1Rate, getAK1DependentParameter(lfo1Rate), getAK1Parameter(lfo1Rate),0};
    _lfo2Rate = {AKSynthOneParameter::lfo2Rate, getAK1DependentParameter(lfo2Rate), getAK1Parameter(lfo2Rate),0};
    _autoPanRate = {AKSynthOneParameter::autoPanFrequency, getAK1DependentParameter(autoPanFrequency), getAK1Parameter(autoPanFrequency),0};
    _delayTime = {AKSynthOneParameter::delayTime, getAK1DependentParameter(delayTime),getAK1Parameter(delayTime),0};

    previousProcessMonoPolyStatus = getAK1Parameter(isMono);
    
    *phaser0->MinNotch1Freq = 100;
    *phaser0->MaxNotch1Freq = 800;
    *phaser0->Notch_width = 1000;
    *phaser0->NotchFreq = 1.5;
    *phaser0->VibratoMode = 1;
    *phaser0->depth = 1;
    *phaser0->feedback_gain = 0;
    *phaser0->invert = 0;
    *phaser0->lfobpm = 30;

    *compressorMasterL->ratio = getAK1Parameter(compressorMasterRatio);
    *compressorMasterR->ratio = getAK1Parameter(compressorMasterRatio);
    *compressorReverbInputL->ratio = getAK1Parameter(compressorReverbInputRatio);
    *compressorReverbInputR->ratio = getAK1Parameter(compressorReverbInputRatio);
    *compressorReverbWetL->ratio = getAK1Parameter(compressorReverbWetRatio);
    *compressorReverbWetR->ratio = getAK1Parameter(compressorReverbWetRatio);
    *compressorMasterL->thresh = getAK1Parameter(compressorMasterThreshold);
    *compressorMasterR->thresh = getAK1Parameter(compressorMasterThreshold);
    *compressorReverbInputL->thresh = getAK1Parameter(compressorReverbInputThreshold);
    *compressorReverbInputR->thresh = getAK1Parameter(compressorReverbInputThreshold);
    *compressorReverbWetL->thresh = getAK1Parameter(compressorReverbWetThreshold);
    *compressorReverbWetR->thresh = getAK1Parameter(compressorReverbWetThreshold);
    *compressorMasterL->atk = getAK1Parameter(compressorMasterAttack);
    *compressorMasterR->atk = getAK1Parameter(compressorMasterAttack);
    *compressorReverbInputL->atk = getAK1Parameter(compressorReverbInputAttack);
    *compressorReverbInputR->atk = getAK1Parameter(compressorReverbInputAttack);
    *compressorReverbWetL->atk = getAK1Parameter(compressorReverbWetAttack);
    *compressorReverbWetR->atk = getAK1Parameter(compressorReverbWetAttack);
    *compressorMasterL->rel = getAK1Parameter(compressorMasterRelease);
    *compressorMasterR->rel = getAK1Parameter(compressorMasterRelease);
    *compressorReverbInputL->rel = getAK1Parameter(compressorReverbInputRelease);
    *compressorReverbInputR->rel = getAK1Parameter(compressorReverbInputRelease);
    *compressorReverbWetL->rel = getAK1Parameter(compressorReverbWetRelease);
    *compressorReverbWetR->rel = getAK1Parameter(compressorReverbWetRelease);

    loPassInputDelayL->freq = getAK1Parameter(cutoff);
    loPassInputDelayL->res = getAK1Parameter(delayInputResonance);
    loPassInputDelayR->freq = getAK1Parameter(cutoff);
    loPassInputDelayR->res = getAK1Parameter(delayInputResonance);

    // Reserve arp note cache to reduce possibility of reallocation on audio thread.
    arpSeqNotes.reserve(maxArpSeqNotes);
    arpSeqNotes2.reserve(maxArpSeqNotes);
    arpSeqLastNotes.resize(maxArpSeqNotes);
    
    // initializeNoteStates() must be called AFTER init returns, BEFORE process, turnOnKey, and turnOffKey
}

void AKSynthOneDSPKernel::destroy() {
    for(int i = 0; i< AKSynthOneParameter::AKSynthOneParameterCount; i++) {
        if (aks1p[i].usePortamento) {
            sp_port_destroy(&aks1p[i].portamento);
        }
    }
    sp_port_destroy(&monoFrequencyPort);

    sp_ftbl_destroy(&sine);
    sp_phasor_destroy(&lfo1Phasor);
    sp_phasor_destroy(&lfo2Phasor);
    sp_phaser_destroy(&phaser0);
    sp_osc_destroy(&panOscillator);
    sp_pan2_destroy(&pan);
    sp_moogladder_destroy(&loPassInputDelayL);
    sp_moogladder_destroy(&loPassInputDelayR);
    sp_vdelay_destroy(&delayL);
    sp_vdelay_destroy(&delayR);
    sp_vdelay_destroy(&delayRR);
    sp_vdelay_destroy(&delayFillIn);
    sp_delay_destroy(&widenDelay);
    sp_crossfade_destroy(&delayCrossfadeL);
    sp_crossfade_destroy(&delayCrossfadeR);
    sp_revsc_destroy(&reverbCostello);
    sp_buthp_destroy(&butterworthHipassL);
    sp_buthp_destroy(&butterworthHipassR);
    sp_crossfade_destroy(&revCrossfadeL);
    sp_crossfade_destroy(&revCrossfadeR);
    sp_compressor_destroy(&compressorMasterL);
    sp_compressor_destroy(&compressorMasterR);
    sp_compressor_destroy(&compressorReverbInputL);
    sp_compressor_destroy(&compressorReverbInputR);
    sp_compressor_destroy(&compressorReverbWetL);
    sp_compressor_destroy(&compressorReverbWetR);
    free(noteStates);
    free(monoNote);
}

// initializeNoteStates() must be called AFTER init returns
void AKSynthOneDSPKernel::initializeNoteStates() {
    if (initializedNoteStates == false) {
        initializedNoteStates = true;
        // POLY INIT
        for (int i = 0; i < AKS1_MAX_POLYPHONY; i++) {
            NoteState& state = noteStates[i];
            state.kernel = this;
            state.init();
            state.stage = NoteState::stageOff;
            state.internalGate = 0;
            state.rootNoteNumber = -1;
        }
        
        // MONO INIT
        monoNote->kernel = this;
        monoNote->init();
        monoNote->stage = NoteState::stageOff;
        monoNote->internalGate = 0;
        monoNote->rootNoteNumber = -1;
    }
}

void AKSynthOneDSPKernel::setupWaveform(uint32_t waveform, uint32_t size) {
    tbl_size = size;
    sp_ftbl_create(sp, &ft_array[waveform], tbl_size);
}

void AKSynthOneDSPKernel::setWaveformValue(uint32_t waveform, uint32_t index, float value) {
    ft_array[waveform]->tbl[index] = value;
}







///parameter min
float AKSynthOneDSPKernel::parameterMin(AKSynthOneParameter i) {
    return aks1p[i].min;
}

///parameter max
float AKSynthOneDSPKernel::parameterMax(AKSynthOneParameter i) {
    return aks1p[i].max;
}

///parameter defaults
float AKSynthOneDSPKernel::parameterDefault(AKSynthOneParameter i) {
    return parameterClamp(i, aks1p[i].defaultValue);
}

AudioUnitParameterUnit AKSynthOneDSPKernel::parameterUnit(AKSynthOneParameter i) {
    return aks1p[i].unit;
}

///return clamped value
float AKSynthOneDSPKernel::parameterClamp(AKSynthOneParameter i, float inputValue) {
    const float paramMin = aks1p[i].min;
    const float paramMax = aks1p[i].max;
    const float retVal = std::min(std::max(inputValue, paramMin), paramMax);
    return retVal;
}

///parameter friendly name as c string
const char* AKSynthOneDSPKernel::parameterCStr(AKSynthOneParameter i) {
    return aks1p[i].friendlyName.c_str();
}

///parameter friendly name
std::string AKSynthOneDSPKernel::parameterFriendlyName(AKSynthOneParameter i) {
    return aks1p[i].friendlyName;
}

///parameter presetKey
std::string AKSynthOneDSPKernel::parameterPresetKey(AKSynthOneParameter i) {
    return aks1p[i].presetKey;
}

// algebraic taper and inverse for input range [0,1]
inline float AKSynthOneDSPKernel::taper01(float inputValue01, float taper) {
    return powf(inputValue01, 1.f / taper);
}
inline float AKSynthOneDSPKernel::taper01Inverse(float inputValue01, float taper) {
    return powf(inputValue01, taper);
}

// algebraic and exponential taper and inverse generalized for all ranges
inline float AKSynthOneDSPKernel::taper(float inputValue01, float min, float max, float taper) {
    if ( (min == 0.f || max == 0.f) && (taper < 0.f) ) {
        printf("can have a negative taper with a range that includes 0\n");
        return min;
    }
    
    if (taper > 0.f) {
        // algebraic taper
        return powf((inputValue01 - min )/(max - min), 1.f / taper);
    } else {
        // exponential taper
        return min * expf(logf(max/min) * inputValue01);
    }
}

inline float AKSynthOneDSPKernel::taperInverse(float inputValue01, float min, float max, float taper) {
    if ((min == 0.f || max == 0.f) && taper < 0.f) {
        printf("can have a negative taper with a range that includes 0\n");
        return min;
    }
    
    // Avoiding division by zero in this trivial case
    if ((max - min) < FLT_EPSILON) {
        return min;
    }
    
    if (taper > 0.f) {
        // algebraic taper
        return min + (max - min) * pow(inputValue01, taper);
    } else {
        // exponential taper
        float adjustedMinimum = 0.0;
        float adjustedMaximum = 0.0;
        if (min == 0.f) { adjustedMinimum = FLT_EPSILON; }
        if (max == 0.f) { adjustedMaximum = FLT_EPSILON; }
        return logf(inputValue01 / adjustedMinimum) / logf(adjustedMaximum / adjustedMinimum);
    }
}

float AKSynthOneDSPKernel::getAK1Parameter(AKSynthOneParameter param) {
    AKS1Param& s = aks1p[param];
    if (s.usePortamento)
        return s.portamentoTarget;
    else
        return p[param];
}

inline void AKSynthOneDSPKernel::_setAK1Parameter(AKSynthOneParameter param, float inputValue) {
    const float value = parameterClamp(param, inputValue);
    AKS1Param& s = aks1p[param];
    if (s.usePortamento) {
        s.portamentoTarget = value;
    } else {
        p[param] = value;
    }
}

void AKSynthOneDSPKernel::setAK1Parameter(AKSynthOneParameter param, float inputValue) {
    _setAK1ParameterHelper(param, inputValue, true, 0);
}

inline void AKSynthOneDSPKernel::_rateHelper(AKSynthOneParameter param, float inputValue, bool notifyMainThread, int payload) {
    if (getAK1Parameter(tempoSyncToArpRate) > 0.f) {
        // tempo sync
        if (param == lfo1Rate || param == lfo2Rate || param == autoPanFrequency) {
            const float value = parameterClamp(param, inputValue);
            AKS1RateArgs syncdValue = _rate.nearestFrequency(value, getAK1Parameter(arpRate), parameterMin(param), parameterMax(param));
            _setAK1Parameter(param, syncdValue.value);
            DependentParam outputDP = {AKSynthOneParameter::AKSynthOneParameterCount, 0.f, 0.f, 0};
            switch(param) {
                case lfo1Rate:
                    outputDP = _lfo1Rate = {param, syncdValue.value01, syncdValue.value, payload};
                    break;
                case lfo2Rate:
                    outputDP = _lfo2Rate = {param, syncdValue.value01, syncdValue.value, payload};
                    break;
                case autoPanFrequency:
                    outputDP = _autoPanRate = {param, syncdValue.value01, syncdValue.value, payload};
                    break;
                default:
                    break;
            }
            if (notifyMainThread) {
                dependentParameterDidChange(outputDP);
            }
        } else if (param == delayTime) {
            const float value = parameterClamp(param, inputValue);
            AKS1RateArgs syncdValue = _rate.nearestTime(value, getAK1Parameter(arpRate), parameterMin(param), parameterMax(param));
            _setAK1Parameter(param, syncdValue.value);
            _delayTime = {param, 1.f - syncdValue.value01, syncdValue.value, payload};
            DependentParam outputDP = _delayTime;
            if (notifyMainThread) {
                dependentParameterDidChange(outputDP);
            }
        }
    } else {
        // no tempo sync
        _setAK1Parameter(param, inputValue);
        const float val = getAK1Parameter(param);
        const float min = parameterMin(param);
        const float max = parameterMax(param);
        const float val01 = clamp((val - min) / (max - min), 0.f, 1.f);
        if (param == lfo1Rate || param == lfo2Rate || param == autoPanFrequency || param == delayTime) {
            DependentParam outputDP = {AKSynthOneParameter::AKSynthOneParameterCount, 0.f, 0.f, 0};
            switch(param) {
                case lfo1Rate:
                    outputDP = _lfo1Rate = {param, val01, val, payload};
                    break;
                case lfo2Rate:
                    outputDP = _lfo2Rate = {param, val01, val, payload};
                    break;
                case autoPanFrequency:
                    outputDP = _autoPanRate = {param, val01, val, payload};
                    break;
                case delayTime:
                    outputDP = _delayTime = {param, val01, val, payload};
                    break;
                default:
                    break;
            }
            if (notifyMainThread) {
                outputDP = {param, taper01Inverse(outputDP.value01, AKS1_DEPENDENT_PARAM_TAPER), outputDP.value};
                dependentParameterDidChange(outputDP);
            }
        }
    }
}

inline void AKSynthOneDSPKernel::_setAK1ParameterHelper(AKSynthOneParameter param, float inputValue, bool notifyMainThread, int payload) {
    if (param == tempoSyncToArpRate || param == arpRate) {
        _setAK1Parameter(param, inputValue);
        _rateHelper(lfo1Rate, getAK1Parameter(lfo1Rate), notifyMainThread, payload);
        _rateHelper(lfo2Rate, getAK1Parameter(lfo2Rate), notifyMainThread, payload);
        _rateHelper(autoPanFrequency, getAK1Parameter(autoPanFrequency), notifyMainThread, payload);
        _rateHelper(delayTime, getAK1Parameter(delayTime), notifyMainThread, payload);
    } else if (param == lfo1Rate || param == lfo2Rate || param == autoPanFrequency || param == delayTime) {
        // dependent params
        _rateHelper(param, inputValue, notifyMainThread, payload);
    } else {
        // independent params
        _setAK1Parameter(param, inputValue);
    }
}

float AKSynthOneDSPKernel::getAK1DependentParameter(AKSynthOneParameter param) {
    DependentParam dp;
    switch(param) {
        case lfo1Rate: dp = _lfo1Rate; break;
        case lfo2Rate: dp = _lfo2Rate; break;
        case autoPanFrequency: dp = _autoPanRate; break;
        case delayTime: dp = _delayTime; break;
        default:printf("error\n");break;
    }
    
    if (p[tempoSyncToArpRate] > 0.f) {
        return dp.value01;
    } else {
        return taper01Inverse(dp.value01, AKS1_DEPENDENT_PARAM_TAPER);
    }
}

// map normalized input to parameter range
void AKSynthOneDSPKernel::setAK1DependentParameter(AKSynthOneParameter param, float inputValue01, int payload) {
    const bool notify = true;
    switch(param) {
        case lfo1Rate: case lfo2Rate: case autoPanFrequency:
            if (getAK1Parameter(tempoSyncToArpRate) > 0.f) {
                // tempo sync
                AKSynthOneRate rate = _rate.rateFromFrequency01(inputValue01);
                const float val = _rate.frequency(getAK1Parameter(arpRate), rate);
                _setAK1ParameterHelper(param, val, notify, payload);
            } else {
                // no tempo sync
                const float min = parameterMin(param);
                const float max = parameterMax(param);
                const float taperValue01 = taper01(inputValue01, AKS1_DEPENDENT_PARAM_TAPER);
                const float val = min + taperValue01 * (max - min);
                _setAK1ParameterHelper(param, val, notify, payload);
            }
            break;
        case delayTime:
            if (getAK1Parameter(tempoSyncToArpRate) > 0.f) {
                // tempo sync
                const float valInvert = 1.f - inputValue01;
                AKSynthOneRate rate = _rate.rateFromTime01(valInvert);
                const float val = _rate.time(getAK1Parameter(arpRate), rate);
                _setAK1ParameterHelper(delayTime, val, notify, payload);
            } else {
                // no tempo sync
                const float min = parameterMin(delayTime);
                const float max = parameterMax(delayTime);
                const float taperValue01 = taper01(inputValue01, AKS1_DEPENDENT_PARAM_TAPER);
                const float val = min + taperValue01 * (max - min);
                _setAK1ParameterHelper(delayTime, val, notify, payload);
            }
            break;
        default:
            printf("error\n");
            break;
    }
}

void AKSynthOneDSPKernel::setParameters(float params[]) {
    for (int i = 0; i < AKSynthOneParameter::AKSynthOneParameterCount; i++) {
        setAK1Parameter((AKSynthOneParameter)i, params[i]);
    }
}

void AKSynthOneDSPKernel::setParameter(AUParameterAddress address, AUValue value) {
    const int i = (AKSynthOneParameter)address;
    setAK1Parameter((AKSynthOneParameter)i, value);
}

AUValue AKSynthOneDSPKernel::getParameter(AUParameterAddress address) {
    const int i = (AKSynthOneParameter)address;
    return p[i];
}

void AKSynthOneDSPKernel::startRamp(AUParameterAddress address, AUValue value, AUAudioFrameCount duration) {}

///AKS1_DEBUG_NOTE_STATE_LOGGING (1) can cause race conditions, and audio artifacts
inline void AKSynthOneDSPKernel::print_debug() {
#if AKS1_DEBUG_NOTE_STATE_LOGGING
    printf("\n-------------------------------------\n");
    printf("\nheldNoteNumbers:\n");
    for (NSNumber* nnn in heldNoteNumbers) {
        printf("%li, ", (long)nnn.integerValue);
    }
    
    if (getAK1Parameter(isMono) > 0.f) {
        printf("\nmonoNote noteNumber:%i, freq:%f, freqSmooth:%f\n",monoNote->rootNoteNumber, monoFrequency, monoFrequencySmooth);
        
    } else {
        printf("\nplayingNotes:\n");
        for(int i=0; i<AKS1_MAX_POLYPHONY; i++) {
            if (playingNoteStatesIndex == i)
                printf("*");
            const int nn = noteStates[i].rootNoteNumber;
            printf("%i:%i, ", i, nn);
        }
    }
    printf("\n-------------------------------------\n");
#endif
}
