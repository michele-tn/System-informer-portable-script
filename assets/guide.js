"use strict";
const $ = (selector) => document.querySelector(selector);
const store = {
  get(key) { try { return localStorage.getItem(key); } catch { return null; } },
  set(key, value) { try { localStorage.setItem(key, value); } catch { /* Browser storage is optional. */ } }
};
const themeButton = $("#theme");
function setTheme(theme) {
  document.documentElement.dataset.theme = theme;
  themeButton.textContent = theme === "dark" ? "Light mode" : "Dark mode";
  themeButton.setAttribute("aria-label", `Switch to ${theme === "dark" ? "light" : "dark"} theme`);
}
setTheme(store.get("si-theme") || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"));
themeButton.addEventListener("click", () => {
  const theme = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
  setTheme(theme); store.set("si-theme", theme);
});
let toastTimer;
function notify(message) {
  clearTimeout(toastTimer); $("#toast").textContent = message;
  toastTimer = setTimeout(() => { $("#toast").textContent = ""; }, 4500);
}
for (const button of document.querySelectorAll("[data-copy]")) {
  button.addEventListener("click", async () => {
    const code = document.getElementById(button.dataset.copy);
    try {
      if (!navigator.clipboard) throw new Error("Clipboard unavailable");
      await navigator.clipboard.writeText(code.textContent);
      notify(button.dataset.copy === 'script-sha3' ? 'SHA3-256 copied to clipboard.' : "Command copied. Paste it into PowerShell in the script's folder.");
    } catch {
      const range = document.createRange(); range.selectNodeContents(code);
      const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
      notify("Automatic copy is unavailable. The command is selected; use Ctrl+C or your browser's Copy action.");
    }
  });
}
const checks = [...document.querySelectorAll("[data-check]")];
function updateChecks() {
  const count = checks.filter((input) => input.checked).length;
  $("#check-count").textContent = `${count} / ${checks.length}`;
  $("#check-progress").value = count;
}
for (const input of checks) {
  input.checked = store.get(`si-check-${input.dataset.check}`) === "true";
  input.addEventListener("change", () => { store.set(`si-check-${input.dataset.check}`, String(input.checked)); updateChecks(); });
}
updateChecks();
$("#reset-checklist").addEventListener("click", () => {
  for (const input of checks) { input.checked = false; store.set(`si-check-${input.dataset.check}`, "false"); }
  updateChecks(); notify("Checklist reset.");
});
const descriptions = {
  launch: "The script checks the latest stable release, prepares it and starts a new administrator instance.",
  prepare: "The script checks the release and prepares the verified portable files. It does not start the application.",
  check: "The script only checks the latest stable release and expected SHA-256. Destination is ignored."
};
function buildCommand() {
  const operation = document.querySelector("input[name=operation]:checked").value;
  const destination = $("#destination").value.trim();
  const invalid = operation !== "check" && /["\r\n\x00]/.test(destination);
  $("#destination").disabled = operation === "check";
  $("#destination").setAttribute("aria-invalid", String(invalid));
  $("#path-error").hidden = !invalid;
  $("#path-error").textContent = invalid ? "Remove double quotes and line breaks from the destination path." : "";
  $("#copy-generated").disabled = invalid;
  let command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\\Start-SystemInformer.ps1"';
  if (operation !== "check" && destination && !invalid) command += ` -Destination '${destination.replaceAll("'", "''")}'`;
  if (operation === "prepare") command += " -NoLaunch";
  if (operation === "check") command += " -CheckOnly";
  $("#generated-command").textContent = invalid ? "Correct the destination path to generate a command." : command;
  $("#mode-help").textContent = descriptions[operation];
}
$("#destination").setAttribute("aria-describedby", "destination-help path-error");
$("#destination").addEventListener("input", buildCommand);
for (const radio of document.querySelectorAll("input[name=operation]")) radio.addEventListener("change", buildCommand);
buildCommand();
const issues = [...document.querySelectorAll("[data-issue]")];
$("#issue-search").addEventListener("input", (event) => {
  const query = event.target.value.trim().toLowerCase();
  let count = 0;
  for (const issue of issues) {
    const matches = issue.textContent.toLowerCase().includes(query);
    issue.hidden = !matches; if (matches) count++;
    if (query && matches) issue.open = true;
    if (!query) issue.open = false;
  }
  $("#search-status").textContent = `${count} ${count === 1 ? "topic" : "topics"} ${query ? "found" : "available"}`;
  $("#no-results").hidden = count !== 0;
});
if ("IntersectionObserver" in window) {
  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) if (entry.isIntersecting) {
      for (const link of document.querySelectorAll(".sidebar nav a")) {
        const active = link.hash === `#${entry.target.id}`;
        link.classList.toggle("active", active);
        if (active) link.setAttribute("aria-current", "location"); else link.removeAttribute("aria-current");
      }
    }
  }, { rootMargin: "-10% 0px -65% 0px", threshold: 0 });
  for (const section of document.querySelectorAll(".section[id]")) observer.observe(section);
}
