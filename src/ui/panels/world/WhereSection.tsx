// Where the character stands: a zone (searched by name) and the coordinates in it, as the game's map shows them (0 to
// 100); moved there at once, or walked there on the game's clock. Clicks on the map can walk too, and the continent's
// loading screen can stand behind the interface where the game draws its world.
import { GeoPin, Route } from "@gravity-ui/icons";
import { Button, ComboBox, Input, Label, ListBox, NumberField } from "@heroui/react";
import { useEffect, useState } from "react";
import { Problem, SwitchRow } from "../../components/bits.tsx";
import { Section } from "../../components/Section.tsx";
import { formatCoordinates } from "../../shell/header/CharacterSummary.tsx";
import { useGameAction, useSimState } from "../../sim/hooks.ts";
import { useMaps } from "../../sim/maps.ts";
import { setPref, usePref } from "../../sim/prefs.ts";

const toPercent = (value: number): number => Math.round(value * 1000) / 10;

const Coordinate = ({
  label,
  value,
  onChange,
}: {
  label: string;
  value: number;
  onChange: (value: number) => void;
}) => (
  <NumberField
    minValue={0}
    maxValue={100}
    step={0.1}
    value={value}
    onChange={(next) => onChange(Number.isFinite(next) ? next : 0)}
    formatOptions={{ maximumFractionDigits: 1 }}
  >
    <Label>{label}</Label>
    <NumberField.Group>
      <NumberField.DecrementButton />
      <NumberField.Input />
      <NumberField.IncrementButton />
    </NumberField.Group>
  </NumberField>
);

export const WhereSection = () => {
  const maps = useMaps();
  const where = useSimState(
    (state) => ({ uiMapId: state.profile.uiMapId, x: state.profile.x, y: state.profile.y }),
    null,
  );
  const zoneName = useSimState((state) => state.zoneName ?? null, null);
  const clickToWalk = useSimState((state) => state.clickToWalk, false);
  const isBackdropOn = usePref("worldBackdrop");
  const action = useGameAction();
  const [mapId, setMapId] = useState<number | null>(null);
  const [x, setX] = useState(50);
  const [y, setY] = useState(50);
  // (the fields start where the character stands, and follow them until the user changes one)
  const [isEdited, setEdited] = useState(false);
  useEffect(() => {
    if (!where || isEdited) return;
    setMapId(where.uiMapId);
    setX(toPercent(where.x));
    setY(toPercent(where.y));
  }, [where, isEdited]);

  const target = { uiMapId: mapId ?? where?.uiMapId ?? 0, x: x / 100, y: y / 100 };
  const go = async (isWalking: boolean): Promise<void> => {
    await action.run(isWalking ? { action: "walkTo", ...target } : { action: "position", ...target });
    setEdited(false);
  };

  return (
    <Section
      title="Where"
      icon={<GeoPin className="size-3.5" />}
      actions={
        where ? (
          <span className="font-mono text-xs text-muted">
            {zoneName ?? where.uiMapId} · {formatCoordinates(where.x, where.y)}
          </span>
        ) : null
      }
    >
      <ComboBox
        items={maps.zones}
        selectedKey={mapId}
        onSelectionChange={(key) => {
          if (key !== null) {
            setMapId(Number(key));
            setEdited(true);
          }
        }}
        fullWidth
      >
        <Label>Zone</Label>
        <ComboBox.InputGroup>
          <Input placeholder="A zone's name" />
          <ComboBox.Trigger />
        </ComboBox.InputGroup>
        <ComboBox.Popover>
          <ListBox>
            {(map: { id: number; name: string }) => (
              <ListBox.Item id={map.id} textValue={map.name}>
                <span className="grow">{map.name}</span>
                <span className="font-mono text-xs text-muted">{map.id}</span>
                <ListBox.ItemIndicator />
              </ListBox.Item>
            )}
          </ListBox>
        </ComboBox.Popover>
      </ComboBox>
      <div className="grid grid-cols-2 gap-3">
        <Coordinate
          label="x"
          value={x}
          onChange={(value) => {
            setX(value);
            setEdited(true);
          }}
        />
        <Coordinate
          label="y"
          value={y}
          onChange={(value) => {
            setY(value);
            setEdited(true);
          }}
        />
      </div>
      <div className="flex gap-2">
        <Button size="sm" isPending={action.isPending} onPress={() => void go(false)}>
          <GeoPin />
          Move there
        </Button>
        <Button size="sm" variant="secondary" isPending={action.isPending} onPress={() => void go(true)}>
          <Route />
          Walk there
        </Button>
      </div>
      <Problem>{action.problem}</Problem>
      <SwitchRow
        label="Click to walk"
        description="A click on the world map or the minimap walks the character there"
        isSelected={clickToWalk}
        onChange={(isOn) => void action.run({ action: "clickToWalk", isOn })}
      />
      <SwitchRow
        label="The world behind the interface"
        description="The game draws its world there; the simulator has none, so the continent's loading screen stands in"
        isSelected={isBackdropOn}
        onChange={(isOn) => setPref("worldBackdrop", isOn)}
      />
    </Section>
  );
};
