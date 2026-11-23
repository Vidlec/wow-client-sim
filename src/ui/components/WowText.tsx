// The game's text with its escapes, as the page's own text: |cAARRGGBB colours (and |cn named ones, in a stand-in
// colour), |r back, |H…|h links shown as their text, ||, and textures and atlases (|T…|t, |A…|a) left out
import { memo, type ReactNode } from "react";

const TOKEN = /\|c([0-9a-fA-F]{8})|\|cn[^:|]*:|\|r|\|H[^|]*\|h|\|h|\|T[^|]*\|t|\|A[^|]*\|a|\|\|/g;
const NAMED_COLOR = "#7FB2FF"; // (a named colour, VISITABLE_URL_DEFAULT_CHAT_LINK_COLOR and the like: a link's blue)

type Run = { text: string; color: string | null };

export const parseWowText = (text: string): Run[] => {
  const runs: Run[] = [];
  const colors: string[] = [];
  let last = 0;
  const push = (part: string): void => {
    if (!part) return;
    const color = colors[colors.length - 1] ?? null;
    const previous = runs[runs.length - 1];
    if (previous && previous.color === color) previous.text += part;
    else runs.push({ text: part, color });
  };
  for (const match of text.matchAll(TOKEN)) {
    push(text.slice(last, match.index));
    last = match.index + match[0].length;
    const token = match[0];
    if (match[1]) colors.push(`#${match[1].slice(2)}`);
    else if (token.startsWith("|cn")) colors.push(NAMED_COLOR);
    else if (token === "|r") colors.pop();
    else if (token === "||") push("|");
  }
  push(text.slice(last));
  return runs;
};

/** Text without any escape: for a title or a search */
export const plainWowText = (text: string): string =>
  parseWowText(text)
    .map((run) => run.text)
    .join("");

type Props = { text: string; color?: string; className?: string };

export const WowText = memo(({ text, color, className }: Props) => {
  const runs = parseWowText(text);
  const parts: ReactNode[] = runs.map((run, index) =>
    run.color ? (
      // biome-ignore lint/suspicious/noArrayIndexKey: the runs of one string, in order, never moved
      <span key={index} style={{ color: run.color }}>
        {run.text}
      </span>
    ) : (
      run.text
    ),
  );
  return (
    <span className={className} style={color ? { color } : undefined}>
      {parts}
    </span>
  );
});
