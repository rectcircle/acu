import { copy } from "./content.js";
import { mirror } from "./mirror-config.js";

// Static HTML keeps the verified link usable without JavaScript.
// When JavaScript is enabled, the public configuration controls availability.
document.querySelector("#quark-download").hidden = true;
document.querySelector("#quark-code").hidden = true;
document.querySelector("#quark-pending").hidden = false;
try {
  const url = new URL(mirror.url);
  if (url.protocol === "https:" && url.hostname === "pan.quark.cn" &&
      /^\/s\/[A-Za-z0-9]+$/.test(url.pathname) && !url.username && !url.password) {
    const link = document.querySelector("#quark-download");
    link.href = url.href;
    link.hidden = false;
    document.querySelector("#quark-pending").hidden = true;
    if (mirror.code) {
      const code = document.querySelector("#quark-code");
      code.querySelector("code").textContent = mirror.code;
      code.hidden = false;
    }
  }
} catch {
  // An empty or invalid URL leaves the existing GitHub download available.
}

const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
let language = "zh";
let motionPaused = false;
let activeTrace = 0;
let mode = "awake";
let lidState = "open";
let lidThreshold = 45;
let lidFrame;
let btState = "armed";
let copyTimer;
let screenshotKind = "menu";
const lidDemo = document.querySelector(".lid-demo");
const lidSlider = document.querySelector("#lid-angle");
const departure = document.querySelector(".departure-demo");
const dialog = document.querySelector("#screenshot-dialog");
const photos = {
  menu: {
    paths: { zh: "/assets/menu-zh.png", en: "/assets/menu-en.png" },
    sizes: { zh: [612, 544], en: [714, 544] },
    title: "menuLink",
    caption: "menuCaption",
    alt: "menuAlt",
  },
  lid: {
    paths: { zh: "/assets/lid-menu-zh.png", en: "/assets/lid-menu-en.png" },
    title: "lidMenuLink",
    caption: "lidMenuCaption",
    alt: "lidMenuAlt",
  },
  bluetooth: {
    paths: { zh: "/assets/bluetooth-menu-zh.png", en: "/assets/bluetooth-menu-en.png" },
    title: "btMenuLink",
    caption: "btMenuCaption",
    alt: "btMenuAlt",
  },
};
const t = (key) => copy[language][key];

function updateLidStatus() {
  const keys = {
    open: "lidOpen",
    protected: "lidProtected",
    auth: "lidAuth",
    unlocked: "lidUnlocked",
  };
  document.querySelector("#lid-status").textContent = t(keys[lidState]);
  lidDemo.dataset.state = lidState;
}
function updateBluetoothStatus() {
  const keys = {
    armed: "btConnected",
    pending: "btDisconnected",
    protected: "btShielded",
    returned: "btReturned",
    auth: "btAuth",
    unlocked: "btUnlocked",
  };
  departure.dataset.state = btState;
  document.querySelector("#bt-status").textContent = t(keys[btState]);
  for (const step of document.querySelectorAll("[data-step]")) {
    const active = ["protected", "returned", "auth", "unlocked"].includes(
      btState,
    )
      ? "protected"
      : btState;
    step.classList.toggle("is-active", step.dataset.step === active);
  }
  document.querySelector("#bt-leave").disabled = btState !== "armed";
  document.querySelector("#bt-return").disabled = ![
    "pending",
    "protected",
  ].includes(btState);
}
function updatePhoto() {
  const photo = photos[screenshotKind];
  document.querySelector("#screenshot-title").textContent = t(photo.title);
  document.querySelector("#screenshot-caption").textContent =
    `${t(photo.caption)} · ${t("screenshotNote")}`;
  const image = document.querySelector("#screenshot-image");
  image.src = photo.paths[language];
  image.alt = t(photo.alt);
}
function setLanguage(next, persist = false) {
  if (!copy[next]) return;
  language = next;
  document.documentElement.lang = next === "zh" ? "zh-CN" : "en";
  document.title = t("title");
  document.querySelector('meta[name="description"]').content = t("description");
  document.querySelector('meta[property="og:title"]').content = t("title");
  document.querySelector('meta[property="og:description"]').content =
    t("description");
  document.querySelector('meta[property="og:locale"]').content =
    next === "zh" ? "zh_CN" : "en_US";
  for (const element of document.querySelectorAll("[data-i18n]"))
    element.textContent = t(element.dataset.i18n);
  for (const element of document.querySelectorAll("[data-i18n-aria]"))
    element.setAttribute("aria-label", t(element.dataset.i18nAria));
  for (const element of document.querySelectorAll("[data-i18n-alt]"))
    element.alt = t(element.dataset.i18nAlt);
  for (const button of document.querySelectorAll("[data-language]"))
    button.setAttribute(
      "aria-pressed",
      String(button.dataset.language === next),
    );
  for (const image of document.querySelectorAll("[data-shield]"))
    image.src = `/assets/shield-${next}.png?v=2`;
  for (const image of document.querySelectorAll("[data-menu]")) {
    image.src = photos.menu.paths[next];
    [image.width, image.height] = photos.menu.sizes[next];
  }
  updateLidStatus();
  updateBluetoothStatus();
  updatePhoto();
  document
    .querySelector(".motion-control")
    .setAttribute("aria-label", t(motionPaused ? "resume" : "pause"));
  document.querySelector("#copy-status").textContent = "";
  if (persist) {
    try {
      localStorage.setItem("acu-language", next);
    } catch {
      /* Language works even if storage is disabled. */
    }
    const url = new URL(location.href);
    url.searchParams.set("lang", next);
    history.replaceState(null, "", url);
  }
}
let initialLanguage = new URL(location.href).searchParams.get("lang");
if (!copy[initialLanguage]) {
  try {
    initialLanguage = localStorage.getItem("acu-language");
  } catch {
    /* Use Chinese by default. */
  }
}
setLanguage(copy[initialLanguage] ? initialLanguage : "zh");
for (const button of document.querySelectorAll("[data-language]"))
  button.addEventListener("click", () =>
    setLanguage(button.dataset.language, true),
  );

const heroVisual = document.querySelector(".hero-visual");
const heroDisplay = heroVisual.querySelector(".hero-display");
const heroShield = heroDisplay.querySelector(".native-shield");
function setMode(next) {
  mode = next;
  heroVisual.dataset.mode = next;
  heroShield.setAttribute("aria-hidden", String(next === "awake"));
  for (const button of document.querySelectorAll("button[data-mode]"))
    button.setAttribute("aria-pressed", String(button.dataset.mode === next));
}
// 首屏随滚动连续过渡：--mode-progress 由 0（仅阻止系统锁屏）线性变到 1
//（模拟锁屏），菜单栏淡出与保护层淡入都跟随滚动位置，而不是一次性切换。
// 行程与视口高度解耦并限制上限，避免高分辨率屏幕下滚出屏幕仍未过渡完。
function modeRange() {
  const travel = Math.min(90, Math.max(50, heroVisual.offsetHeight * 0.15));
  return { start: 0, end: travel };
}
let modeQueued = false;
let modeProgress = -1;
let manualProgress = null; // null 表示跟随滚动
let manualDir = 0; // 手动切换后的当前滚动方向：1 向下，-1 向上
let lastScrollY = scrollY;
function applyProgress(progress) {
  if (progress === modeProgress) return;
  modeProgress = progress;
  heroVisual.style.setProperty("--mode-progress", progress.toFixed(3));
  setMode(progress >= 0.5 ? "protected" : "awake");
}
function syncModeWithScroll() {
  modeQueued = false;
  const delta = scrollY - lastScrollY;
  lastScrollY = scrollY;
  if (manualProgress !== null) {
    if (delta !== 0) manualDir = delta > 0 ? 1 : -1;
    // 模拟锁屏的自然方向是向下，仅阻止是向上。顺着这个方向滚动时保持
    // 手动结果、不播放动画；只有反向滚动才把控制权交还滚动位置。
    const natural = manualProgress === 1 ? 1 : -1;
    if (manualDir === 0 || manualDir === natural) return;
    manualProgress = null;
  }
  const { start, end } = modeRange();
  const ratio = (scrollY - start) / (end - start);
  const clamped = Math.min(Math.max(ratio, 0), 1);
  applyProgress(reducedMotion.matches ? (clamped > 0.5 ? 1 : 0) : clamped);
}
function queueModeSync() {
  if (modeQueued) return;
  modeQueued = true;
  requestAnimationFrame(syncModeWithScroll);
}
addEventListener("scroll", queueModeSync, { passive: true });
addEventListener("resize", queueModeSync, { passive: true });
// 点击按钮手动切换模式，不改变页面滚动位置。
for (const button of document.querySelectorAll("button[data-mode]"))
  button.addEventListener("click", () => {
    manualProgress = button.dataset.mode === "protected" ? 1 : 0;
    manualDir = 0;
    applyProgress(manualProgress);
  });
syncModeWithScroll();

/* 半合上屏幕：倾角由滚动驱动，也可拖动角度条手动控制。 */
const lidScreen = document.querySelector(".laptop-screen");
const lidAngleOutput = document.querySelector("#angle-output");
const lidAngleReadout = document.querySelector(".angle-readout");
const lidUnlock = document.querySelector("#lid-unlock");
const LID_OPEN = 100;
const LID_CLOSED = 20;
let lidAngle = LID_OPEN;
let lidManual = null; // null 表示跟随滚动；否则为手动角度
let lidManualDir = 0; // 手动后的当前滚动方向：1 向下，-1 向上
let lidQueued = false;
let lastLidScroll = scrollY;
let lidReplaying = false;

function evaluateLid() {
  if (lidState === "protected" || lidState === "auth") {
    // 锁定后重新展开：越过阈值即要求指纹认证，未解锁前保持遮罩。
    if (lidAngle > lidThreshold + 4) lidState = "auth";
    else if (lidAngle < lidThreshold) lidState = "protected";
    updateLidStatus();
    return;
  }
  // 只要低于阈值就直接进入模拟锁屏，不再有“稳定 2 秒”的过渡。
  const next = lidAngle < lidThreshold ? "protected" : "open";
  if (next !== lidState) {
    lidState = next;
    updateLidStatus();
  }
}
function applyAngle(value, evaluate = true) {
  lidAngle = Math.round(value);
  lidSlider.value = String(lidAngle);
  lidAngleOutput.textContent = `${lidAngle}°`;
  lidAngleReadout.textContent = `${lidAngle}°`;
  // 90° 竖直；角度越小越向内（朝键盘）合拢。
  lidScreen.style.transform = `rotateX(${lidAngle - 90}deg)`;
  if (evaluate) evaluateLid();
}
function lidRange() {
  // 等笔记本与下方控件整体进入视野、且底部再上移一段距离后才开始合拢，
  // 保证触发时整个模块都已经稳定可见。
  const rect = lidDemo.getBoundingClientRect();
  const slack = Math.max(0, innerHeight - rect.height);
  const lead = Math.min(96, slack * 0.4);
  const shown = innerHeight - rect.bottom - lead;
  const travel = Math.max(100, Math.min(180, slack - lead));
  return Math.min(Math.max(shown / travel, 0), 1);
}
function syncLidWithScroll() {
  lidQueued = false;
  const delta = scrollY - lastLidScroll;
  lastLidScroll = scrollY;
  if (lidReplaying) return;
  if (lidManual !== null) {
    if (delta !== 0) lidManualDir = delta > 0 ? 1 : -1;
    // 合上（向下滚动）与展开（向上滚动）各自的自然方向，方向一致时保持手动结果。
    const natural = lidManual < lidThreshold ? 1 : -1;
    if (lidManualDir === 0 || lidManualDir === natural) return;
    lidManual = null;
  }
  const next = Math.round(LID_OPEN + (LID_CLOSED - LID_OPEN) * lidRange());
  if (next !== lidAngle) applyAngle(next);
}
function queueLidSync() {
  if (lidQueued) return;
  lidQueued = true;
  requestAnimationFrame(syncLidWithScroll);
}
addEventListener("scroll", queueLidSync, { passive: true });
addEventListener("resize", queueLidSync, { passive: true });
lidSlider.addEventListener("input", () => {
  cancelAnimationFrame(lidFrame);
  lidReplaying = false;
  lidManual = Number(lidSlider.value);
  lidManualDir = 0;
  applyAngle(lidManual);
});
for (const button of document.querySelectorAll("[data-threshold]"))
  button.addEventListener("click", () => {
    lidThreshold = Number(button.dataset.threshold);
    for (const option of document.querySelectorAll("[data-threshold]"))
      option.setAttribute("aria-pressed", String(option === button));
    cancelAnimationFrame(lidFrame);
    lidReplaying = false;
    lidManual = lidAngle;
    lidManualDir = 0;
    evaluateLid();
  });
lidUnlock.addEventListener("click", () => {
  if (lidState !== "auth") return;
  lidState = "unlocked";
  updateLidStatus();
});
function replayLid() {
  cancelAnimationFrame(lidFrame);
  lidReplaying = false;
  lidManualDir = 0;
  const destination = lidThreshold - 12;
  // 先直接回到未锁屏状态（不走“重新展开需要认证”的分支），再重新演示合盖过程。
  lidManual = LID_OPEN;
  lidState = "open";
  applyAngle(LID_OPEN, false);
  updateLidStatus();
  // 减少动效时也保留可见的重置，不再瞬间跳回演示终点。
  if (reducedMotion.matches) return;
  lidReplaying = true;
  // 留一小段停留时间，让重置后的状态先被看到。
  const start = performance.now() + 480;
  const animate = (now) => {
    const time = Math.min((now - start) / 1600, 1);
    if (time > 0) {
      const ease = time * time * (3 - 2 * time);
      applyAngle(LID_OPEN + (destination - LID_OPEN) * ease);
    }
    if (time < 1) lidFrame = requestAnimationFrame(animate);
    else {
      lidManual = lidAngle;
      lidManualDir = 0;
      lidReplaying = false;
    }
  };
  lidFrame = requestAnimationFrame(animate);
}
document.querySelector("#lid-replay").addEventListener("click", replayLid);
syncLidWithScroll();

/* 人自然离开：手机随滚动远离，越过断连阶段后自动进入模拟锁屏。 */
let btProgress = 0;
// 保护一旦开启就锁存：手机再回到身边也不会自动解锁，必须按 Enter 验证。
let btLatched = false;
let btManual = false;
let btManualDir = 0;
let btQueued = false;
let btFrame;
let lastBtScroll = scrollY;
let btReplaying = false;

function btStateForProgress(progress) {
  if (progress >= 0.72) {
    btLatched = true;
    return "protected";
  }
  if (btLatched) return progress < 0.35 ? "returned" : "protected";
  return progress >= 0.35 ? "pending" : "armed";
}
function applyDeparture(progress, state) {
  btProgress = Math.min(Math.max(progress, 0), 1);
  departure.style.setProperty("--depart-progress", btProgress.toFixed(3));
  btState = state;
  updateBluetoothStatus();
}
function departRange() {
  const rect = departure.getBoundingClientRect();
  const slack = Math.max(0, innerHeight - rect.height);
  const lead = Math.min(96, slack * 0.4);
  const shown = innerHeight - rect.bottom - lead;
  const travel = Math.max(100, Math.min(200, slack - lead));
  return Math.min(Math.max(shown / travel, 0), 1);
}
function syncDepartureWithScroll() {
  btQueued = false;
  const delta = scrollY - lastBtScroll;
  lastBtScroll = scrollY;
  if (btReplaying) return;
  if (btManual) {
    if (delta !== 0) btManualDir = delta > 0 ? 1 : -1;
    // 手机已远离（向下滚动）或已收回（向上滚动）时保持手动结果。
    const natural = btProgress > 0.5 ? 1 : -1;
    if (btManualDir === 0 || btManualDir === natural) return;
    btManual = false;
  }
  const progress = departRange();
  const state = btStateForProgress(progress);
  if (progress === btProgress && state === btState) return;
  applyDeparture(progress, state);
}
function queueDepartureSync() {
  if (btQueued) return;
  btQueued = true;
  requestAnimationFrame(syncDepartureWithScroll);
}
addEventListener("scroll", queueDepartureSync, { passive: true });
addEventListener("resize", queueDepartureSync, { passive: true });
document.querySelector("#bt-leave").addEventListener("click", () => {
  cancelAnimationFrame(btFrame);
  btReplaying = false;
  btManual = true;
  btManualDir = 0;
  btLatched = true;
  applyDeparture(1, "protected");
});
document.querySelector("#bt-return").addEventListener("click", () => {
  cancelAnimationFrame(btFrame);
  btReplaying = false;
  btManual = true;
  btManualDir = 0;
  // 断连确认期内收回手机取消离开；已保护时手机返回不会自动解锁。
  applyDeparture(0, btLatched ? "returned" : "armed");
});
document.querySelector("#bt-unlock").addEventListener("click", () => {
  if (btState !== "auth") return;
  btLatched = false;
  applyDeparture(btProgress, "unlocked");
});
// 保护中按 Enter 发起认证，验证指纹后才解除保护。
addEventListener("keydown", (event) => {
  if (event.key !== "Enter") return;
  const target = event.target;
  if (target instanceof Element && target.closest("button, a, input, summary"))
    return;
  if (btState !== "protected" && btState !== "returned") return;
  event.preventDefault();
  cancelAnimationFrame(btFrame);
  btReplaying = false;
  btManual = true;
  btManualDir = 0;
  applyDeparture(btProgress, "auth");
});
document.querySelector("#bt-replay").addEventListener("click", () => {
  cancelAnimationFrame(btFrame);
  btReplaying = false;
  btManual = true;
  btManualDir = 0;
  // 先清掉解锁/保护状态，回到“已布防”，再重新演示离开过程。
  btLatched = false;
  applyDeparture(0, "armed");
  if (reducedMotion.matches) return;
  btReplaying = true;
  // 留一小段停留时间，让重置后的状态先被看到。
  const start = performance.now() + 480;
  const animate = (now) => {
    const time = Math.min((now - start) / 1600, 1);
    if (time > 0) {
      const ease = time * time * (3 - 2 * time);
      applyDeparture(ease, btStateForProgress(ease));
    }
    if (time < 1) btFrame = requestAnimationFrame(animate);
    else {
      btReplaying = false;
      btManualDir = 0;
    }
  };
  btFrame = requestAnimationFrame(animate);
});
syncDepartureWithScroll();

const motionButton = document.querySelector(".motion-control");
motionButton.addEventListener("click", () => {
  motionPaused = !motionPaused;
  document.body.classList.toggle("motion-paused", motionPaused);
  motionButton.textContent = motionPaused ? "▷" : "Ⅱ";
  motionButton.setAttribute("aria-label", t(motionPaused ? "resume" : "pause"));
  if (motionPaused) {
    cancelAnimationFrame(lidFrame);
    cancelAnimationFrame(btFrame);
    lidReplaying = false;
    btReplaying = false;
    if (lidManual !== null) lidManual = lidAngle;
  } else {
    evaluateLid();
  }
});
const traceRows = [...document.querySelectorAll(".trace-row")];
setInterval(() => {
  if (motionPaused || reducedMotion.matches || document.hidden || !heroVisible)
    return;
  activeTrace = (activeTrace + 1) % traceRows.length;
  traceRows.forEach((row, index) =>
    row.classList.toggle("is-active", index === activeTrace),
  );
}, 2200);
let heroVisible = true;
if ("IntersectionObserver" in window) {
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.target.classList.contains("hero-visual"))
          heroVisible = entry.isIntersecting;
        if (!entry.isIntersecting) continue;
        entry.target.classList.add("in-view");
      }
    },
    { threshold: 0.25 },
  );
  for (const element of document.querySelectorAll(
    ".reveal, .hero-visual, .lid-demo, .departure-demo",
  ))
    observer.observe(element);
}

for (const button of document.querySelectorAll("[data-screenshot]"))
  button.addEventListener("click", () => {
    screenshotKind = button.dataset.screenshot;
    updatePhoto();
    dialog.showModal();
  });
document
  .querySelector("#close-screenshot")
  .addEventListener("click", () => dialog.close());
dialog.addEventListener("click", (event) => {
  const bounds = dialog.getBoundingClientRect();
  if (
    event.target === dialog &&
    (event.clientX < bounds.left ||
      event.clientX > bounds.right ||
      event.clientY < bounds.top ||
      event.clientY > bounds.bottom)
  )
    dialog.close();
});

const copyTargets = {
  brew: "#brew-command",
  quarantine: "#quarantine-command",
};
for (const button of document.querySelectorAll("[data-copy]"))
  button.addEventListener("click", async () => {
    button.disabled = true;
    clearTimeout(copyTimer);
    try {
      await navigator.clipboard.writeText(
        document
          .querySelector(copyTargets[button.dataset.copy])
          .textContent.trim(),
      );
      button.textContent = t("copied");
      document.querySelector("#copy-status").textContent = t("copySuccess");
    } catch {
      document.querySelector("#copy-status").textContent = t("copyFailure");
    } finally {
      button.disabled = false;
      setTimeout(() => {
        button.textContent = t("copy");
      }, 2000);
      copyTimer = setTimeout(() => {
        document.querySelector("#copy-status").textContent = "";
      }, 7000);
    }
  });
