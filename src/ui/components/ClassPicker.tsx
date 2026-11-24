// A class picked from a grid: each class with the game's own icon (Interface\Icons\ClassIcon_<Class>) and its name in
// its colour, the chosen one outlined and tinted in that colour
import { useFlavour } from "../flavours/index.ts";

type Props = { value: string; onChange: (classFile: string) => void; label?: string };

/** The game's icon of a class: "MAGE" -> ClassIcon_Mage (the game's paths are read in any case) */
const getClassIconUrl = (classFile: string): string =>
  `/art?p=${encodeURIComponent(`Interface/Icons/ClassIcon_${classFile.charAt(0)}${classFile.slice(1).toLowerCase()}`)}`;

export const ClassPicker = ({ value, onChange, label = "Class" }: Props) => {
  const flavour = useFlavour();
  return (
    <fieldset className="flex flex-col">
      <legend className="mb-2 text-sm font-medium">{label}</legend>
      <div className="grid grid-cols-3 gap-1.5">
        {flavour.classes.map((entry) => {
          const isChosen = entry.file === value;
          return (
            <button
              key={entry.file}
              type="button"
              aria-pressed={isChosen}
              onClick={() => onChange(entry.file)}
              className="flex cursor-pointer items-center gap-2 rounded-lg border px-2 py-1.5 text-left text-[13px] font-medium transition-colors hover:bg-default focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
              style={{
                color: entry.color,
                borderColor: isChosen ? entry.color : "var(--separator)",
                background: isChosen ? `color-mix(in oklab, ${entry.color} 14%, transparent)` : undefined,
              }}
            >
              <img
                src={getClassIconUrl(entry.file)}
                alt=""
                className="size-6 shrink-0 rounded-[5px]"
                style={{ opacity: isChosen ? 1 : 0.7 }}
              />
              <span className="truncate">{entry.name}</span>
            </button>
          );
        })}
      </div>
    </fieldset>
  );
};
