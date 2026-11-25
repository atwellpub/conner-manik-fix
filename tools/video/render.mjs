// Renders the install walkthrough from storyboard.html and the pictures in shots/:
//
//     docs/install-guide.mp4   the video, 1920x1080, for sharing
//     docs/install-guide.gif   the same thing as a half-size animation, which is
//                              what the README shows (GitHub will not play an MP4
//                              that lives in a repository)
//
//     cd tools/video
//     npm install          (once: fetches playwright-core, which drives Chrome)
//     node render.mjs
//
// Needs Node 18 or newer, Google Chrome, and ffmpeg on the PATH. It was written
// to run under WSL or Linux. On another machine, set CHROME_PATH to a Chrome or
// Chromium executable if Chrome is not installed in the usual place.
//
// How it works: storyboard.html can draw any moment of the video. This script
// asks it for one frame at a time, photographs each frame, and pipes the
// pictures to ffmpeg. Nothing is recorded in real time, so the result is the
// same on every run.
//
//     node render.mjs --stills 2,10,26     writes single frames to out/ instead,
//                                          for checking the layout quickly
//     node render.mjs --gif                remakes only the animation, from the
//                                          video that is already there

import { chromium } from "playwright-core";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const output = join(here, "..", "..", "docs", "install-guide.mp4");
const animation = join(here, "..", "..", "docs", "install-guide.gif");
const FPS = 30;
const WIDTH = 1280, HEIGHT = 720, SCALE = 1.5;      // drawn at 1280x720, saved at 1920x1080

const args = process.argv.slice(2);

// The animation is made from the finished video: 10 frames a second, 960 wide,
// with its own 128-colour palette and no dithering, which keeps flat areas flat
// and the file small.
async function writeAnimation() {
  const filter = "fps=10,scale=960:-1:flags=lanczos,split[a][b];"
    + "[a]palettegen=stats_mode=diff:max_colors=128[p];[b][p]paletteuse=dither=none:diff_mode=rectangle";
  const pass = spawn("ffmpeg", ["-y", "-loglevel", "error", "-i", output, "-vf", filter, "-loop", "0", animation], { stdio: "inherit" });
  const [code] = await once(pass, "close");
  if (code !== 0) throw new Error(`ffmpeg failed with exit code ${code} while writing the animation`);
  console.log(`wrote ${animation}`);
}

if (args.includes("--gif")) {
  if (!existsSync(output)) throw new Error("docs/install-guide.mp4 is missing. Run node render.mjs first.");
  await writeAnimation();
  process.exit(0);
}
const stillsAt = args.includes("--stills") ? args[args.indexOf("--stills") + 1].split(",").map(Number) : null;

for (const name of ["installer-1", "installer-2", "app-off", "app-tick1", "app-tick2", "app-on", "app-test-w", "app-test-up", "icon-on"]) {
  if (!existsSync(join(here, "shots", name + ".png"))) throw new Error(`shots/${name}.png is missing. Run capture.ps1 first.`);
}
const layout = JSON.parse(readFileSync(join(here, "shots", "layout.json"), "utf8").replace(/^﻿/, ""));

const launch = { headless: true, args: ["--allow-file-access-from-files", "--font-render-hinting=none"] };
if (process.env.CHROME_PATH) launch.executablePath = process.env.CHROME_PATH; else launch.channel = "chrome";
const browser = await chromium.launch(launch);
const page = await browser.newPage({ viewport: { width: WIDTH, height: HEIGHT }, deviceScaleFactor: SCALE });
await page.goto(pathToFileURL(join(here, "storyboard.html")).href);

// The captions use Segoe UI, the Windows interface font, when this machine has
// it. Under WSL it is read straight from the Windows fonts folder. It is not
// copied into the project. Without it the page falls back to the system font.
const fonts = [["segoeui.ttf", 400], ["seguisb.ttf", 600], ["segoeuib.ttf", 700]]
  .map(([file, weight]) => [join("/mnt/c/Windows/Fonts", file), weight])
  .filter(([path]) => existsSync(path));
if (fonts.length) {
  // Handed to the page as data, so no browser file-access rule can get in the way.
  await page.addStyleTag({
    content: fonts.map(([path, weight]) =>
      `@font-face { font-family: "Segoe UI"; font-weight: ${weight}; src: url(data:font/ttf;base64,${readFileSync(path).toString("base64")}); }`).join("\n"),
  });
}
const fontsLoaded = await page.evaluate(async () => {
  await Promise.all([...document.images].map(image => image.decode()));
  await Promise.all([400, 600, 700].map(weight => document.fonts.load(`${weight} 20px "Segoe UI"`).catch(() => null)));
  await document.fonts.ready;
  return document.fonts.check('600 20px "Segoe UI"');
});
console.log(fontsLoaded ? "captions use Segoe UI" : "Segoe UI was not found, captions use the system font");
await page.evaluate(data => window.init(data), layout);
const duration = await page.evaluate(() => window.DURATION);

if (stillsAt) {
  mkdirSync(join(here, "out"), { recursive: true });
  for (const seconds of stillsAt) {
    await page.evaluate(t => window.renderAt(t), seconds);
    const file = join(here, "out", `still-${seconds.toFixed(1).padStart(4, "0")}.png`);
    writeFileSync(file, await page.screenshot({ type: "png" }));
    console.log("wrote", file);
  }
  await browser.close();
  process.exit(0);
}

mkdirSync(dirname(output), { recursive: true });
const ffmpeg = spawn("ffmpeg", [
  "-y", "-loglevel", "error",
  "-f", "image2pipe", "-framerate", String(FPS), "-i", "-",
  "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-tune", "stillimage",
  "-pix_fmt", "yuv420p",                 // the pixel format every player and Discord can show
  "-movflags", "+faststart",             // lets it start playing before it has fully downloaded
  "-an", output,
], { stdio: ["pipe", "inherit", "inherit"] });

const frames = Math.round(duration * FPS);
for (let frame = 0; frame < frames; frame++) {
  await page.evaluate(t => window.renderAt(t), frame / FPS);
  const picture = await page.screenshot({ type: "png" });
  if (!ffmpeg.stdin.write(picture)) await once(ffmpeg.stdin, "drain");
  if (frame % 150 === 0) console.log(`frame ${frame} of ${frames}`);
}
ffmpeg.stdin.end();
const [code] = await once(ffmpeg, "close");
await browser.close();
if (code !== 0) throw new Error(`ffmpeg failed with exit code ${code}`);
console.log(`wrote ${output} (${frames} frames, ${duration} seconds)`);
await writeAnimation();
