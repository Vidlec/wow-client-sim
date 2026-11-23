// Numbers printed as Python's format() prints them, so the reports read as they did before the port.

/**
 * x with this many decimals, rounded as Python's "{:.Nf}" rounds: to the nearest, and an exact tie to the even digit
 * (toFixed takes the tie upwards: 12.5 is "13" there, "12" in Python). Meant for the runner's times and percentages,
 * which are never negative.
 */
export const pyFixed = (x: number, digits: number): string => {
  const rounded = x.toFixed(digits);
  // A double near the sizes printed here has an exact decimal form well within 60 more digits
  const exact = x.toFixed(Math.min(100, digits + 60));
  const dot = exact.indexOf(".");
  const cut = dot + (digits > 0 ? digits + 1 : 0);
  const rest = exact.slice(dot + digits + 1);
  if (!/^50*$/.test(rest)) return rounded;
  const truncated = exact.slice(0, digits > 0 ? cut : dot);
  const lastDigit = Number(truncated.at(-1));
  return lastDigit % 2 === 0 ? truncated : rounded;
};
