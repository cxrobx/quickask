import { useEffect } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useMailStore } from "@/stores/mailStore";

/** Publish only selection coordinates. Rust resolves labels from its database.
 * Writes are serialized so a slower earlier invoke cannot replace a new selection. */
export function useQuickAskSelection() {
  useEffect(() => {
    let stopped = false;
    let previous = "";
    let queue: Promise<unknown> = Promise.resolve();
    const publish = () => {
      if (stopped) return;
      const state = useMailStore.getState();
      const lookup = state.isUnifiedInbox || state.selectedGroupId != null || state.specialView === "needs_you" || state.specialView === "snoozed" || state.specialView === "followups";
      const selection = {
        account_id: state.selectedMessageAccountId ?? (lookup ? null : state.selectedAccountId),
        folder: state.selectedMessageFolder ?? (lookup ? "INBOX" : state.selectedFolder),
        uid: state.selectedMessageUids.size > 1 ? null : state.selectedMessageUid,
        composing: state.isComposing,
        view: state.specialView ?? state.selectedFolder ?? "Inbox",
      };
      const key = JSON.stringify(selection);
      if (key === previous) return;
      previous = key;
      queue = queue.then(() => stopped ? undefined : invoke("publish_quickask_selection", { selection })).catch(() => { previous = ""; });
    };
    publish();
    const unsubscribe = useMailStore.subscribe(publish);
    const interval = setInterval(publish, 2000); // retry unavailable startup IPC, no screen capture
    return () => { stopped = true; unsubscribe(); clearInterval(interval); };
  }, []);
}
