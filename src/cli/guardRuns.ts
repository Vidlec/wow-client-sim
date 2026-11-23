// A stopped run leaves nothing behind. On Windows a child process outlives its parent unless told otherwise, so the
// runner puts itself in a job object that ends every process it starts when the runner itself ends (however it ends),
// and ends itself when the process that started it (a shell closed, a task stopped) is gone. Elsewhere a stopped
// shell's signal reaches the whole process group, and nothing is needed.
import { dlopen, FFIType } from "bun:ffi";

const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION = 9;
const SYNCHRONIZE = 0x00100000;
const WAIT_OBJECT_0 = 0;
// JOBOBJECT_EXTENDED_LIMIT_INFORMATION on 64-bit Windows: 64 bytes of basic limits (LimitFlags at byte 16), 48 of
// I/O counters, four sizes of 8 bytes
const EXTENDED_LIMITS_SIZE = 144;
const LIMIT_FLAGS_OFFSET = 16;
const PARENT_CHECK_MS = 2000;

/** Kept for the runner's life: closing the job (the runner ending) ends the runs */
const keptOpen: unknown[] = [];

export const guardRuns = (name: string): void => {
  if (process.platform !== "win32") return;
  try {
    const kernel32 = dlopen("kernel32.dll", {
      CreateJobObjectW: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
      SetInformationJobObject: { args: [FFIType.ptr, FFIType.i32, FFIType.ptr, FFIType.u32], returns: FFIType.i32 },
      AssignProcessToJobObject: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.i32 },
      GetCurrentProcess: { args: [], returns: FFIType.ptr },
      OpenProcess: { args: [FFIType.u32, FFIType.i32, FFIType.u32], returns: FFIType.ptr },
      WaitForSingleObject: { args: [FFIType.ptr, FFIType.u32], returns: FFIType.u32 },
    }).symbols;
    const handle = kernel32.CreateJobObjectW(null, null);
    if (handle) {
      const limits = new Uint8Array(EXTENDED_LIMITS_SIZE);
      new DataView(limits.buffer).setUint32(LIMIT_FLAGS_OFFSET, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, true);
      kernel32.SetInformationJobObject(handle, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION, limits, EXTENDED_LIMITS_SIZE);
      kernel32.AssignProcessToJobObject(handle, kernel32.GetCurrentProcess());
      keptOpen.push(handle);
    }
    const parent = kernel32.OpenProcess(SYNCHRONIZE, 0, process.ppid);
    if (!parent) return;
    // Polled without waiting (a wait of 0 ms), so the check never holds the runner up; unref'd, so it never keeps
    // the runner alive either
    const timer = setInterval(() => {
      if (kernel32.WaitForSingleObject(parent, 0) !== WAIT_OBJECT_0) return;
      process.stderr.write(`\n${name}: whatever started it has stopped; ending its runs\n`);
      process.exit(1);
    }, PARENT_CHECK_MS);
    timer.unref();
  } catch {
    // No job (an older Windows, FFI unavailable): runs then end with the runner only when stopped by Ctrl+C
  }
};
