// The game's sounds, played by the page (lua/sound.lua decides them): each frame of the stream says what started (a
// handle, where to fetch it, its volume, whether it loops) and what stopped; the page plays them and says when each
// ended, so the game's C_Sound.IsPlaying and SOUNDKIT_FINISHED follow the real sound. Sound can be switched off on
// the page (kept per browser). A browser lets a page make sound only after the player has clicked or pressed a key
// in it: what was asked for before then starts at that first click.

export type SoundEvent = {
  k: "play" | "stop";
  /** The sound's handle in the game */
  h: number;
  src?: string;
  /** 0 to 1: the channel's volume times the master's */
  v?: number;
  loop?: boolean;
  /** Seconds to fade out over (StopSound's fadeout) */
  fade?: number;
};

const STORAGE_KEY = "addonsim.sound";
const FADE_STEP_MS = 50;

const readIsOn = (): boolean => {
  try {
    return localStorage.getItem(STORAGE_KEY) !== "off";
  } catch {
    return true;
  }
};

let isOn = readIsOn();
const listeners = new Set<(isOn: boolean) => void>();

/** Sound on the page (on by default) */
export const isSoundOn = (): boolean => isOn;

export const setSoundOn = (on: boolean): void => {
  isOn = on;
  try {
    localStorage.setItem(STORAGE_KEY, on ? "on" : "off");
  } catch {
    // (no storage: for this visit only)
  }
  for (const listener of listeners) listener(on);
};

export const onSoundSwitched = (listener: (isOn: boolean) => void): (() => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};

export type AudioPlayer = {
  apply: (events: readonly SoundEvent[]) => void;
  /** Everything stopped (a new game: its handles start again) */
  stopAll: () => void;
  close: () => void;
};

export const createAudioPlayer = (onEnded: (handle: number) => void): AudioPlayer => {
  const playing = new Map<number, HTMLAudioElement>();
  const waitingForClick = new Set<number>();

  /** A sound over; given its element, only while that element still plays the handle (handles start again after a
   * reload: an old element ending late must not end the new sound) */
  const end = (handle: number, element?: HTMLAudioElement): void => {
    const audio = playing.get(handle);
    if (!audio || (element && audio !== element)) return;
    playing.delete(handle);
    waitingForClick.delete(handle);
    onEnded(handle);
  };

  const start = (handle: number, audio: HTMLAudioElement): void => {
    audio.play().catch((problem: unknown) => {
      // Not yet allowed to make sound: at the first click; any other failure (no such file) ends it
      if (problem instanceof DOMException && problem.name === "NotAllowedError") waitingForClick.add(handle);
      else end(handle);
    });
  };

  const unlock = (): void => {
    for (const handle of waitingForClick) {
      const audio = playing.get(handle);
      if (audio) start(handle, audio);
    }
    waitingForClick.clear();
  };
  window.addEventListener("pointerdown", unlock, true);
  window.addEventListener("keydown", unlock, true);

  const stop = (handle: number, fadeSeconds?: number): void => {
    const audio = playing.get(handle);
    if (!audio) return;
    playing.delete(handle);
    waitingForClick.delete(handle);
    if (!fadeSeconds || fadeSeconds <= 0 || audio.paused) {
      audio.pause();
      return;
    }
    const steps = Math.max(1, Math.round((fadeSeconds * 1000) / FADE_STEP_MS));
    const from = audio.volume;
    let step = 0;
    const timer = setInterval(() => {
      step += 1;
      audio.volume = Math.max(0, from * (1 - step / steps));
      if (step >= steps) {
        clearInterval(timer);
        audio.pause();
      }
    }, FADE_STEP_MS);
  };

  const stopAll = (): void => {
    for (const handle of [...playing.keys()]) stop(handle);
  };
  const stopOnSwitchOff = onSoundSwitched((on) => {
    if (!on) stopAll();
  });

  return {
    apply: (events) => {
      for (const event of events) {
        if (event.k === "stop") {
          stop(event.h, event.fade);
          continue;
        }
        // (switched off: nothing plays; the game ends the sound on its own clock, by the file's length)
        if (!isOn || !event.src) continue;
        const audio = new Audio(event.src);
        audio.volume = Math.min(1, Math.max(0, event.v ?? 1));
        audio.loop = event.loop === true;
        audio.addEventListener("ended", () => end(event.h, audio));
        audio.addEventListener("error", () => end(event.h, audio));
        playing.set(event.h, audio);
        start(event.h, audio);
      }
    },
    stopAll,
    close: () => {
      stopAll();
      stopOnSwitchOff();
      window.removeEventListener("pointerdown", unlock, true);
      window.removeEventListener("keydown", unlock, true);
    },
  };
};
