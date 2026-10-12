(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const storage = {get(key) {try {return localStorage.getItem(key);} catch {return null;}}, set(key,value) {try {localStorage.setItem(key,value);} catch {}}};
  const themeButton = $('theme');
  function setTheme(theme) {
    document.documentElement.dataset.theme = theme;
    const next = theme === 'dark' ? 'light' : 'dark';
    themeButton.textContent = next === 'light' ? 'Light mode' : 'Dark mode';
    themeButton.setAttribute('aria-label', 'Switch to ' + next + ' theme');
  }
  const storedTheme = storage.get('si-theme');
  setTheme(storedTheme === 'light' ? 'light' : 'dark');
  themeButton.addEventListener('click', () => {const theme = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark'; setTheme(theme); storage.set('si-theme', theme);});
  let toastTimer;
  function notify(message) { $('toast').textContent = message; $('toast').classList.add('visible'); clearTimeout(toastTimer); toastTimer = setTimeout(() => $('toast').classList.remove('visible'), 3200); }
  async function copyText(value) {
    if (navigator.clipboard && window.isSecureContext) {try {await navigator.clipboard.writeText(value); return true;} catch {}}
    const field = document.createElement('textarea'); field.value = value; field.style.position = 'fixed'; field.style.opacity = '0'; document.body.append(field);
    const previous = document.activeElement; field.select();
    let copied = false; try {copied = document.execCommand('copy');} catch {}
    field.remove(); previous?.focus(); return copied;
  }
  document.querySelectorAll('[data-copy]').forEach(button => button.addEventListener('click', async () => {
    const target = $(button.dataset.copy); notify(await copyText(target.textContent) ? 'Copied to clipboard.' : 'Copy unavailable. Select the command text and copy it manually.');
  }));
  const checks = [...document.querySelectorAll('[data-check]')];
  checks.forEach(check => {check.checked = storage.get('si-check-' + check.dataset.check) === 'true'; check.addEventListener('change', updateChecklist);});
  function updateChecklist() {const count = checks.filter(check => check.checked).length; $('check-count').textContent = count + ' / 4'; $('check-progress').value = count; checks.forEach(check => storage.set('si-check-' + check.dataset.check, String(check.checked)));}
  $('reset-checklist').addEventListener('click', () => {checks.forEach(check => check.checked = false); updateChecklist();}); updateChecklist();
  const help = {launch:'Checks online, prepares the verified archive and launches an administrator instance.',prepare:'Adds -NoLaunch. The script still requests administrator elevation and prepares the application.',check:'Adds -CheckOnly. The script still requests administrator elevation, then reads release metadata without downloading the application or creating its workspace.'};
  function buildCommand() {
    const operation = document.querySelector('input[name=operation]:checked').value;
    const path = $('destination').value.trim();
    const invalid = /["\r\n\x00-\x1f]/.test(path) || (path && !/^(?:[a-zA-Z]:\\|\\\\[^\\]+\\[^\\]+)/.test(path));
    $('path-error').hidden = !invalid; $('destination').setAttribute('aria-invalid', String(Boolean(invalid)));
    $('copy-generated').disabled = Boolean(invalid);
    $('path-error').textContent = 'Enter an absolute Windows path (for example D:\\Portable Tools\\SystemInformer), without double quotes or control characters.';
    let command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\\Start-SystemInformer.ps1"';
    if (path) command += ' -Destination "' + (path.endsWith('\\') ? path + '.' : path) + '"';
    if (operation === 'prepare') command += ' -NoLaunch';
    if (operation === 'check') command += ' -CheckOnly';
    $('generated-command').textContent = invalid ? 'Correct the destination path to generate a command.' : command;
    $('mode-help').textContent = help[operation];
  }
  $('destination').addEventListener('input', buildCommand);
  document.querySelectorAll('input[name=operation]').forEach(input => input.addEventListener('change', buildCommand)); buildCommand();
  const issues = [...document.querySelectorAll('[data-issue]')];
  $('issue-search').addEventListener('input', () => {const query = $('issue-search').value.toLowerCase().trim(); let found = 0; issues.forEach(issue => {const matches = issue.textContent.toLowerCase().includes(query); issue.hidden = !matches; if(matches) found++;}); $('search-status').textContent = found + ' of ' + issues.length + ' topics available'; $('no-results').hidden = found !== 0;});
  const navLinks = [...document.querySelectorAll('.sidebar nav a')];
  if ('IntersectionObserver' in window) {
    const observer = new IntersectionObserver(entries => {entries.forEach(entry => {if(entry.isIntersecting) navLinks.forEach(link => {if(link.hash === '#' + entry.target.id) link.setAttribute('aria-current','true'); else link.removeAttribute('aria-current');});});}, {rootMargin:'-5% 0px -65% 0px',threshold:0});
    document.querySelectorAll('.section[id]').forEach(section => observer.observe(section));
  }
})();

