// Where the shell takes the game screen from: the engine (src/ui/engine), behind its contract (engine/types.ts)

export { isSoundOn, onSoundSwitched, setSoundOn } from "../engine/audio.ts";
export { createGameScreen, runPicturePage } from "../engine/index.ts";
