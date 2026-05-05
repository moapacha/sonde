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
  var <synthGroup, <verbSynth, <fxBus, <drones;

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

    // persistent quiet harmonic bed: one per satellite slot. Each drone is
    // a sine + low partials at a fixed root × the slot's freq multiplier, so
    // sats 1..4 form a stable major triad (root / 5th / 4th-below / M3). The
    // active sat's drone is silenced (amp=0) since it's playing leads. Amp,
    // pan and freq are all Lag-smoothed so per-tick updates from Lua glide
    // instead of clicking.
    SynthDef(\sonde_drone, {
      arg out=0, amp=0, freq=110, pan=0;
      var sig, vib, smooth_amp, smooth_pan, smooth_freq;
      smooth_amp  = Lag.kr(amp,  1.5);
      smooth_pan  = Lag.kr(pan,  1.5);
      smooth_freq = Lag.kr(freq, 0.8);
      vib = SinOsc.kr(0.05 + Rand(0, 0.04), 0, 0.0025, 1);
      sig = SinOsc.ar(smooth_freq * vib, 0, 0.5)
          + SinOsc.ar(smooth_freq * 2.001 * vib, 0, 0.18)
          + SinOsc.ar(smooth_freq * 3.005 * vib, 0, 0.06);
      sig = LPF.ar(sig, 1500);
      sig = sig * smooth_amp;
      sig = sig.softclip * 0.7;
      Out.ar(out, Pan2.ar(sig, smooth_pan, 1.0));
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
      [\in, fxBus.index, \out, 0, \mix, 0.32, \room, 0.62, \damp, 0.42]);

    // four persistent drone synths, head of group so they run through the
    // shared verb. Lua keeps the active slot at a soft floor amp (so the
    // chord never goes incomplete) and modulates the others by brightness.
    drones = Array.fill(4, { |i|
      Synth.head(synthGroup, \sonde_drone, [
        \out, fxBus.index,
        \amp, 0,
        \freq, 82.41 * [1.0, 1.5, 0.75, 1.25][i] * [2, 1, 4, 2][i],
        \pan, 0
      ]);
    });

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
      var scale, semis, oct, within, best, bestd;

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

      // pentatonic-major snap rooted at E2 (82.41 Hz) so leads always sit
      // on a scale tone of the drone bed's voicing instead of drifting in
      // continuous freq with terrain/elev/brightness. Done before sat_mul
      // is applied inside the synthdef, so the M3/P5/P4 transposes still
      // land on consonant intervals.
      scale = #[0, 2, 4, 7, 9];
      semis = 12 * (freq / 82.41).log2;
      oct = (semis / 12).floor;
      within = semis - (oct * 12);
      best = scale[0]; bestd = 999;
      scale.do { |s|
        var d = (within - s).abs;
        if(d < bestd, { bestd = d; best = s });
      };
      freq = 82.41 * (2 ** ((oct * 12 + best) / 12));

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

    // drone(idx, amp, freq, pan) - sets one of the four persistent drones.
    // Lua calls this every tick for every slot; smoothing lives inside the
    // synthdef so per-tick step changes glide audibly.
    this.addCommand("drone", "ifff", { arg msg;
      var idx = msg[1].asInteger;
      if((idx >= 1) and: { idx <= 4 }, {
        drones[idx - 1].set(\amp, msg[2], \freq, msg[3], \pan, msg[4]);
      });
    });
  }

  free {
    drones.do({ |d| d.free });
    synthGroup.free;
    fxBus.free;
  }
}
