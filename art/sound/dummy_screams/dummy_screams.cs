// Crash dummy scream sounds — audio asset registration
// Executed once from GE Lua via TorqueScriptLua.call("exec", ...)
// Registers a reusable SFXDescription so that
//   Engine.Audio.playOnce("DummyScreamDesc", path)
// can play a raw OGG file without a pre-registered SFXProfile.

if (!isObject("DummyScreamDesc")) {
    datablock SFXDescription(DummyScreamDesc)
    {
        volume    = 1.0;
        isLooping = false;
        is3D      = false;
    };
}
