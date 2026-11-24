// The Console panel: Lua run in the game's global scope, and the game's chat
import { Chip, Tabs } from "@heroui/react";
import { useSimState } from "../../sim/hooks.ts";
import { ChatLog } from "./ChatLog.tsx";
import { LuaConsole } from "./LuaConsole.tsx";

export const ConsolePanel = () => {
  const chatCount = useSimState((state) => state.chat.length, 0);
  return (
    <Tabs variant="secondary" defaultSelectedKey="lua" className="w-full">
      <Tabs.ListContainer>
        <Tabs.List aria-label="Console">
          <Tabs.Tab id="lua">
            Lua
            <Tabs.Indicator />
          </Tabs.Tab>
          <Tabs.Tab id="chat">
            Chat
            {chatCount > 0 && (
              <Chip size="sm" variant="soft" className="ml-1.5">
                {chatCount}
              </Chip>
            )}
            <Tabs.Indicator />
          </Tabs.Tab>
        </Tabs.List>
      </Tabs.ListContainer>
      <Tabs.Panel id="lua" className="pt-3 data-[inert=true]:hidden" shouldForceMount>
        <LuaConsole />
      </Tabs.Panel>
      <Tabs.Panel id="chat" className="pt-3 data-[inert=true]:hidden" shouldForceMount>
        <ChatLog />
      </Tabs.Panel>
    </Tabs>
  );
};
