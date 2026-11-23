// A Sim whose games run in this process (createSim): its own live game and pool, nothing shared with the daemon.
import type { Project } from "../project/config.ts";
import { Engine, type EngineOptions } from "./engine.ts";
import { SimBase, type SimInfo } from "./sim.ts";
import type {
  EvalResult,
  FramesOptions,
  FramesResult,
  GameState,
  RunOptions,
  RunResult,
  Scene,
  ShotOptions,
  ShotResult,
} from "./types.ts";

export class LocalSim extends SimBase {
  readonly engine: Engine;
  readonly info: SimInfo;

  constructor(
    readonly project: Project,
    options: EngineOptions = {},
  ) {
    super();
    this.engine = new Engine(project, options);
    this.info = {
      root: project.root,
      scenariosDir: project.scenariosDir,
      addons: project.addons.map((addon) => addon.name),
      mode: "local",
    };
  }

  eval(code: string): Promise<EvalResult> {
    return this.engine.eval(code);
  }
  evalFile(path: string): Promise<EvalResult> {
    return this.engine.evalFile(path);
  }
  run(scenario: string, options?: RunOptions): Promise<RunResult & { wasWarm: boolean }> {
    return this.engine.run(scenario, options);
  }
  reset(): Promise<{ wasWarm: boolean; seconds: number }> {
    return this.engine.reset();
  }
  frames(options?: FramesOptions): Promise<FramesResult> {
    return this.engine.frames(options);
  }
  frame(ref: string): Promise<Record<string, unknown>> {
    return this.engine.frame(ref);
  }
  state(): Promise<GameState> {
    return this.engine.state();
  }
  scene(): Promise<Scene> {
    return this.engine.scene();
  }
  host(request: Record<string, unknown> & { op: string }): Promise<Record<string, unknown>> {
    return this.engine.host(request);
  }
  shot(options?: ShotOptions): Promise<ShotResult> {
    return this.engine.shot(options);
  }
  close(): Promise<void> {
    return this.engine.close();
  }
}
