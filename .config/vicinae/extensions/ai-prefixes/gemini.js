const React = require("react");
const {
  Action,
  ActionPanel,
  Clipboard,
  List,
  closeMainWindow,
  open,
} = require("@vicinae/api");

function createPromptCommand({
  navigationTitle,
  openTitle,
  emptyHint,
  buildUrl,
  copyPromptOnOpen = false,
}) {
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
              if (copyPromptOnOpen && trimmed) {
                await Clipboard.copy(trimmed);
              }

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

function geminiUrl(prompt) {
  if (!prompt) {
    return "https://gemini.google.com";
  }

  return `https://gemini.google.com/app?prompt=${encodeURIComponent(prompt)}`;
}

module.exports = {
  default: createPromptCommand({
    navigationTitle: "Gemini",
    openTitle: "Open Gemini in Browser",
    emptyHint: "Continue typing after the ge prefix",
    buildUrl: geminiUrl,
    copyPromptOnOpen: true,
  }),
};
