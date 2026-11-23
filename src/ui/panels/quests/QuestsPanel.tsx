// The Quests panel, in three tabs: your log (moved along by hand), finding a quest (accept, or mark done), and quest
// givers (talk to one, or kill it)
import { Chip, Tabs } from "@heroui/react";
import { useState } from "react";
import { useSimState } from "../../sim/hooks.ts";
import { GiverFinder } from "./GiverFinder.tsx";
import { QuestFinder } from "./QuestFinder.tsx";
import { QuestLog } from "./QuestLog.tsx";

export const QuestsPanel = () => {
  const [tab, setTab] = useState("log");
  const logCount = useSimState((state) => state.questLog.length, 0);
  const doneCount = useSimState((state) => state.completedCount, 0);
  return (
    <Tabs selectedKey={tab} onSelectionChange={(key) => setTab(String(key))} variant="secondary" className="w-full">
      <Tabs.ListContainer>
        <Tabs.List aria-label="Quests">
          <Tabs.Tab id="log">
            Your log
            <Chip size="sm" variant="soft" color="accent" className="ml-1.5">
              {logCount}
            </Chip>
            <Tabs.Indicator />
          </Tabs.Tab>
          <Tabs.Tab id="find">
            Find
            <Tabs.Indicator />
          </Tabs.Tab>
          <Tabs.Tab id="givers">
            Givers
            <Tabs.Indicator />
          </Tabs.Tab>
        </Tabs.List>
      </Tabs.ListContainer>
      <Tabs.Panel id="log" className="pt-3" shouldForceMount>
        <p className="mb-2 text-xs text-muted">{doneCount} done before, besides these</p>
        <QuestLog onFind={() => setTab("find")} />
      </Tabs.Panel>
      <Tabs.Panel id="find" className="pt-3" shouldForceMount>
        <QuestFinder />
      </Tabs.Panel>
      <Tabs.Panel id="givers" className="pt-3" shouldForceMount>
        <GiverFinder />
      </Tabs.Panel>
    </Tabs>
  );
};
