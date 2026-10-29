const rows = document.getElementById("rows");
const problem = document.getElementById("problem");

function row(label, value, level) {
  const r = document.createElement("div");
  r.className = `row ${level}`;
  for (const [cls, text] of [["dot", ""], ["label", label], ["value", value]]) {
    const span = document.createElement("span");
    span.className = cls;
    span.textContent = text;
    r.append(span);
  }
  return r;
}

function render(s) {
  rows.replaceChildren(
    row("Mac app", s.connected ? `Connected${s.appVersion ? `, v${s.appVersion}` : ""}` : "Not connected", s.connected ? "ok" : "warn"),
    row("Translation", s.connected ? (s.ready ? `Ready, into ${s.targetLanguage || "English"}` : "Needs setup") : "–", s.ready ? "ok" : "warn"),
    row("Extension", `v${chrome.runtime.getManifest().version}`, "ok"),
  );
  problem.hidden = !s.problem || (s.connected && s.ready);
  problem.textContent = s.problem || "";
}

function refresh(type = "popupStatus") {
  chrome.runtime.sendMessage({ type }).then(render, () => render({ connected: false, problem: "The extension's background worker isn't responding." }));
}

document.getElementById("settings").addEventListener("click", () => {
  chrome.runtime.sendMessage({ type: "openSettings", tab: "connections" }).finally(() => window.close());
});
document.getElementById("reconnect").addEventListener("click", () => refresh("reconnect"));
refresh();
