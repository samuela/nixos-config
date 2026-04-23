const React = require("react");
const { Action, ActionPanel, List, closeMainWindow, open } = require("@vicinae/api");

function createPromptCommand({ navigationTitle, openTitle, emptyHint, buildUrl }) {
  return function PromptCommand() {
    const [query, setQuery] = React.useState("");
    const trimmed = query.trim();

    return React.createElement(
      List,
      {
        filtering: false,
        navigationTitle,
        searchBarPlaceholder: "Type a prompt, then press Enter",
        searchText: query,
        onSearchTextChange: setQuery,
      },
      React.createElement(List.Item, {
        id: "open-ai-chat",
        title: openTitle,
        subtitle: trimmed || emptyHint,
        actions: React.createElement(
          ActionPanel,
          null,
          React.createElement(Action, {
            title: openTitle,
            onAction: async () => {
              await open(buildUrl(trimmed));
              await closeMainWindow();
            },
          }),
          trimmed
            ? React.createElement(Action.CopyToClipboard, {
                title: "Copy Prompt",
                content: trimmed,
              })
            : null,
        ),
      }),
    );
  };
}

function claudeUrl(prompt) {
  if (!prompt) {
    return "https://claude.ai/new";
  }

  return `https://claude.ai/new?q=${encodeURIComponent(prompt)}`;
}

module.exports = {
  default: createPromptCommand({
    navigationTitle: "Claude Web",
    openTitle: "Open Claude in Browser",
    emptyHint: "Continue typing after the cl prefix",
    buildUrl: claudeUrl,
  }),
};
