// Who is playing where, in the header: the character's portrait, name in their class's colour, race, class and level,
// the zone and the coordinates. A press opens a card with the rest (money, experience, faction, the instance).
import { ArrowRight, MapPin } from "@gravity-ui/icons";
import { Button, Label, Meter, Popover } from "@heroui/react";
import { Facts } from "../../components/bits.tsx";
import { Money } from "../../components/Money.tsx";
import { Portrait } from "../../components/Portrait.tsx";
import { findClass, findFaction, findRace, useFlavour } from "../../flavours/index.ts";
import { useSimState } from "../../sim/hooks.ts";
import type { Profile } from "../../sim/types.ts";
import { showPanel } from "../navigation.ts";

export const formatCoordinates = (x: number, y: number): string => `${(x * 100).toFixed(1)}, ${(y * 100).toFixed(1)}`;

export const CharacterSummary = () => {
  const flavour = useFlavour();
  const profile = useSimState((state): Profile | null => state.profile, null);
  const zone = useSimState((state) => state.zoneName ?? null, null);
  if (!profile) return null;
  const classInfo = findClass(flavour, profile.class);
  const race = profile.raceName ?? findRace(flavour, profile.race).name;
  const faction = findFaction(flavour, profile.faction ?? findRace(flavour, profile.race).faction);

  return (
    <Popover>
      <Popover.Trigger>
        <button
          type="button"
          className="flex min-w-0 cursor-pointer items-center gap-2 rounded-lg px-1.5 py-1 text-left hover:bg-surface-secondary"
          aria-label={`${profile.name}, ${race} ${classInfo.name} ${profile.level}: more`}
        >
          <Portrait name={profile.name} classFile={profile.class} level={profile.level} size="sm" />
          <span className="flex min-w-0 flex-col leading-tight">
            <span className="truncate text-[13px] font-semibold" style={{ color: classInfo.color }}>
              {profile.name}
            </span>
            <span className="truncate text-[11px] text-muted">
              {zone ? `${zone} · ${formatCoordinates(profile.x, profile.y)}` : `${race} ${classInfo.name}`}
            </span>
          </span>
        </button>
      </Popover.Trigger>
      <Popover.Content placement="bottom" className="w-72">
        <Popover.Dialog className="flex flex-col gap-3 p-4">
          <div className="flex items-center gap-3">
            <Portrait name={profile.name} classFile={profile.class} level={profile.level} />
            <div className="min-w-0">
              <Popover.Heading className="truncate text-base font-semibold" style={{ color: classInfo.color }}>
                {profile.name}
              </Popover.Heading>
              <p className="text-xs text-muted">
                Level {profile.level} {race} {classInfo.name}
              </p>
              <p className="text-xs font-medium" style={{ color: faction.color }}>
                {faction.name}
                {profile.realm ? ` · ${profile.realm}` : ""}
              </p>
            </div>
          </div>
          {profile.xpMax ? (
            <Meter
              aria-label="Experience"
              value={profile.xp ?? 0}
              maxValue={profile.xpMax}
              size="sm"
              color="accent"
              className="xp-meter"
            >
              <Label className="text-[11px] text-muted">Experience</Label>
              <Meter.Output className="text-[11px] text-muted">
                {(profile.xp ?? 0).toLocaleString()} / {profile.xpMax.toLocaleString()}
              </Meter.Output>
              <Meter.Track>
                <Meter.Fill />
              </Meter.Track>
            </Meter>
          ) : null}
          <Facts
            rows={[
              ["Money", <Money key="money" copper={profile.money} />],
              [
                "Where",
                <span key="where" className="inline-flex items-center gap-1">
                  <MapPin className="size-3 text-muted" />
                  {zone ?? profile.uiMapId} · {formatCoordinates(profile.x, profile.y)}
                </span>,
              ],
              ...(profile.isInInstance
                ? [["Inside", profile.instanceName ?? `instance ${profile.instanceId}`] as const]
                : []),
            ]}
          />
          <div className="flex gap-2">
            <Button size="sm" variant="secondary" onPress={() => showPanel("character")} className="grow">
              Character
              <ArrowRight />
            </Button>
            <Button size="sm" variant="tertiary" onPress={() => showPanel("world")} className="grow">
              World
              <ArrowRight />
            </Button>
          </div>
        </Popover.Dialog>
      </Popover.Content>
    </Popover>
  );
};
