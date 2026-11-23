// A class picked by its colour: a row of discs in the classes' colours, the chosen one ringed, its name under them
import { findClass, useFlavour } from "../flavours/index.ts";

type Props = { value: string; onChange: (classFile: string) => void; label?: string };

export const ClassPicker = ({ value, onChange, label = "Class" }: Props) => {
  const flavour = useFlavour();
  const chosen = findClass(flavour, value);
  return (
    <fieldset className="flex flex-col gap-2">
      <legend className="mb-2 text-sm font-medium">{label}</legend>
      <div className="flex flex-wrap justify-between gap-1">
        {flavour.classes.map((entry) => {
          const isChosen = entry.file === value;
          return (
            <button
              key={entry.file}
              type="button"
              aria-label={entry.name}
              aria-pressed={isChosen}
              title={entry.name}
              onClick={() => onChange(entry.file)}
              className="size-7 cursor-pointer rounded-full transition-transform hover:scale-110 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
              style={{
                background: `radial-gradient(circle at 35% 30%, #fff6, ${entry.color} 55%)`,
                opacity: isChosen ? 1 : 0.45,
                boxShadow: isChosen ? `0 0 0 2px #13161a, 0 0 0 4px ${entry.color}, 0 0 14px ${entry.color}88` : "none",
              }}
            />
          );
        })}
      </div>
      <span className="text-[13px] font-medium" style={{ color: chosen.color }}>
        {chosen.name}
      </span>
    </fieldset>
  );
};
