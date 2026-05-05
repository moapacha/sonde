// Engine_Sonde
// sound engine for "sonde / listening earth"
//
// four terrain profiles trigger short events:
//   ocean    -> low filtered drone (long tail, events overlap into a wash)
//   land     -> resonant pluck     (short percussive)
//   mountain -> FM spike + peak    (resonant, pitched to elevation)
//   ice      -> bell partials      (long sparkle decay)
//
// each event also takes a per-satellite freq multiplier (sat_mul) so
// different satellites stack into chord intervals on the same terrain.
//
// brightness modulates amp and filter cutoff. elevation modulates pitch.
// pan comes from current longitude.
//
// fifth profile, fired only when two satellite ground tracks cross:
//   intersect -> chord bloom (slow attack, long resonant tail).
//
// every voice softclips before pan, and the entire group runs through
// a light FreeVerb2 send so individual hits glue together.

Engine_Sonde : CroneEngine {
  var <synthGroup, <verbSynth, <fxBus;

  *new { arg context, doneCallback;
    ^super.new(context, doneCallback);
  }

  alloc {
    fxBus       = Bus.audio(context.server, 2);
    synthGroup  = Group.new(context.xg);

    SynthDef(\sonde_verb, {
      arg in=0, out=0, mix=0.28, room=0.62, damp=0.42;
      var dry = In.ar(in, 2);
      var wet = FreeVerb2.ar(dry[0], dry[1], 1.0, room, damp);
      Out.ar(out, (dry * (1 - mix)) + (wet * mix));
    }).add;

    SynthDef(\sonde_ocean, {
      arg out=0, freq=80, amp=0.3, dur=2.0, pan=0, bright=0.5, sat_mul=1.0;
      var sig, env, mod, cutoff, f;
      f = freq * sat_mul;
      env = EnvGen.kr(
        Env.new([0, 1, 0.7, 0], [0.4, dur*0.5, dur*0.5], \sine),
        doneAction: 2);
      mod = LFTri.kr(LFNoise2.kr(0.1).range(0.07, 0.18), 0, 0.4, 1.0);
      cutoff = (f * (4 + bright * 6)) * mod;
      sig = LFTri.ar(f, 0, 0.30)
          + SinOsc.ar(f * 2.005, 0, 0.10)
          + LFSaw.ar(f * 0.5, 0, 0.04);
      sig = LPF.ar(sig, cutoff);
      sig = sig + (LPF.ar(WhiteNoise.ar(0.03), 600) * env);
      sig = sig * env * amp;
      sig = sig.softclip * 0.85;
      sig = Pan2.ar(sig, pan, 1.0);
      Out.ar(out, sig);
    }).add;

    SynthDef(\sonde_land, {
      arg out=0, freq=400, amp=0.4, dur=0.4, pan=0, bright=0.5, sat_mul=1.0;
      var sig, env, exc, ratios, f;
      f = freq * sat_mul;
      env = EnvGen.kr(Env.perc(0.005, dur, 1, -4), doneAction: 2);
      exc = (PinkNoise.ar(0.4) + Impulse.ar(0, 0, 0.5))
          * EnvGen.kr(Env.perc(0.001, 0.04));
      ratios = [1.0, 1.498, 2.32];
      sig = Mix.fill(3, { |i| Resonz.ar(exc, f * ratios[i], 0.05) }) * 3.5;
      sig = sig + (SinOsc.ar(f, 0, 0.16) * env);
      sig = HPF.ar(sig, 120);
      sig = sig * env * amp * (0.6 + bright * 0.4);
      sig = sig.softclip * 0.9;
      sig = Pan2.ar(sig, pan, 1.0);
      Out.ar(out, sig);
    }).add;

    SynthDef(\sonde_mountain, {
      arg out=0, freq=600, amp=0.4, dur=0.7, pan=0, bright=0.5, sat_mul=1.0;
      var sig, env, mod, peak, f;
      f = freq * sat_mul;
      env = EnvGen.kr(Env.perc(0.005, dur, 1, -3), doneAction: 2);
      mod = SinOsc.ar(f * 1.732, 0,
        f * (0.7 + bright * 1.0) * EnvGen.kr(Env.perc(0.001, dur * 0.5)));
      sig = SinOsc.ar(f + mod, 0, 0.40);
      peak = Resonz.ar(PinkNoise.ar(0.5) * env, f * 2, 0.06) * 2.5;
      sig = sig + peak;
      sig = HPF.ar(sig, 80);
      sig = sig * env * amp * (0.6 + bright * 0.4);
      sig = sig.softclip * 0.9;
      sig = Pan2.ar(sig, pan, 0.95);
      Out.ar(out, sig);
    }).add;

    SynthDef(\sonde_ice, {
      arg out=0, freq=1500, amp=0.35, dur=1.6, pan=0, bright=0.5, sat_mul=1.0;
      var sig, env, partials, shimmer, f, vib;
      f = freq * sat_mul;
      env = EnvGen.kr(Env.perc(0.001, dur, 1, -3), doneAction: 2);
      partials = Klank.ar(
        `[
          [1000, 2756, 5404, 8933],
          [1.0,  0.5,  0.25, 0.12],
          [3.5,  3.0,  2.5,  2.0]
        ],
        Impulse.ar(0) * 0.22,
        f / 1000
      );
      vib = SinOsc.kr(5, 0, 0.005, 1);
      shimmer = SinOsc.ar(f * 4 * vib, 0, 0.05)
              * EnvGen.kr(Env.perc(0.02, 0.4));
      sig = partials + shimmer + (SinOsc.ar(f, 0, 0.13) * env);
      sig = HPF.ar(sig, 400);
      sig = sig * env * amp * (0.6 + bright * 0.4);
      sig = sig.softclip * 0.9;
      sig = Pan2.ar(sig, pan, 0.85);
      Out.ar(out, sig);
    }).add;

    SynthDef(\sonde_intersect, {
      arg out=0, freq=220, amp=0.4, dur=4.5, pan=0;
      var sig, env, ratios, mix;
      env = EnvGen.kr(
        Env.new([0, 1, 0.7, 0], [0.6, dur*0.4, dur*0.6], \sine),
        doneAction: 2);
      ratios = [1.0, 1.25, 1.5, 1.875, 2.0];
      mix = Mix.fill(5, { |i|
        SinOsc.ar(freq * ratios[i] * LFNoise2.kr(0.3, 0.005, 1), 0,
          0.18 / (i + 1))
      });
      sig = mix + (Klank.ar(
        `[ [220, 330, 440, 660, 880, 1320],
           [1.0, 0.7, 0.5, 0.35, 0.2, 0.12],
           [4.0, 3.5, 3.0, 2.5, 2.0, 1.5] ],
        Impulse.ar(0) * 0.06,
        freq / 220
      ) * 0.4);
      sig = LPF.ar(sig, 6000);
      sig = sig * env * amp;
      sig = sig.softclip * 0.9;
      sig = Pan2.ar(sig, pan, 1.0);
      Out.ar(out, sig);
    }).add;

    context.server.sync;

    verbSynth = Synth.tail(synthGroup, \sonde_verb,
      [\in, fxBus.index, \out, 0, \mix, 0.28, \room, 0.62, \damp, 0.42]);

    // trigger(terrain, brightness, elevation, pan, dur, sat_mul)
    //   terrain: 0=ocean, 1=land, 2=ice, 3=mountain
    this.addCommand("trigger", "ifffff", { arg msg;
      var terrain    = msg[1].asInteger;
      var brightness = msg[2];
      var elevation  = msg[3];
      var pan        = msg[4];
      var dur        = msg[5];
      var sat_mul    = msg[6];
      var def, freq, amp;

      if(terrain == 0, {
        def  = \sonde_ocean;
        freq = 50 + (elevation * 40) + (brightness * 20);
        amp  = 0.16 + (brightness * 0.16);
      });
      if(terrain == 1, {
        def  = \sonde_land;
        freq = 200 * (1.0 + elevation * 1.6) * (0.85 + brightness * 0.4);
        amp  = 0.18 + (brightness * 0.28);
      });
      if(terrain == 2, {
        def  = \sonde_ice;
        freq = 1100 + (elevation * 1600) + (brightness * 400);
        amp  = 0.16 + (brightness * 0.20);
      });
      if(terrain == 3, {
        def  = \sonde_mountain;
        freq = 350 * (1.0 + elevation * 1.8);
        amp  = 0.18 + (brightness * 0.26);
      });

      Synth(def, [
        \out, fxBus.index,
        \freq, freq, \amp, amp, \dur, dur,
        \pan, pan, \bright, brightness, \sat_mul, sat_mul
      ], target: synthGroup);
    });

    // intersect(freq, amp, pan) - fired when two satellite ground tracks cross
    this.addCommand("intersect", "fff", { arg msg;
      Synth(\sonde_intersect, [
        \out, fxBus.index,
        \freq, msg[1], \amp, msg[2], \pan, msg[3], \dur, 4.5
      ], target: synthGroup);
    });
  }

  free {
    synthGroup.free;
    fxBus.free;
  }
}
