// Comparing states that arrive as new objects twice a second: the parts that did not change keep the objects the
// page already holds, so components fed from them do not draw again

type Plain = Record<string, unknown>;

const isPlainObject = (value: unknown): value is Plain =>
  typeof value === "object" && value !== null && Object.getPrototypeOf(value) === Object.prototype;

/** The next value, with every part deeply equal to the previous one's taken from the previous (as React Query does) */
export const replaceEqualDeep = <T>(previous: unknown, next: T): T => {
  if (previous === next) return next;
  const isArray = Array.isArray(previous) && Array.isArray(next);
  if (!isArray && !(isPlainObject(previous) && isPlainObject(next))) return next;
  const before = previous as Plain;
  const after = next as Plain;
  const keys = isArray ? null : Object.keys(after);
  const length = isArray ? (next as unknown[]).length : (keys?.length ?? 0);
  const result: Plain | unknown[] = isArray ? new Array<unknown>(length) : {};
  let same = isArray ? (previous as unknown[]).length === length : Object.keys(before).length === length;
  for (let index = 0; index < length; index++) {
    const key = isArray ? index : (keys?.[index] ?? "");
    const value = replaceEqualDeep(before[key], after[key]);
    (result as Plain)[key] = value;
    if (value !== before[key] || (!isArray && !(key in before))) same = false;
  }
  return (same ? previous : result) as T;
};

/** Equal at the top: the same object, or arrays or objects whose items are each the same */
export const shallowEqual = (first: unknown, second: unknown): boolean => {
  if (Object.is(first, second)) return true;
  if (Array.isArray(first) && Array.isArray(second)) {
    return first.length === second.length && first.every((value, index) => Object.is(value, second[index]));
  }
  if (isPlainObject(first) && isPlainObject(second)) {
    const keys = Object.keys(first);
    return keys.length === Object.keys(second).length && keys.every((key) => Object.is(first[key], second[key]));
  }
  return false;
};
