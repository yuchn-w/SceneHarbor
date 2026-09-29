/* IINA 1.4.4: verified against JavascriptAPI{Mpv,Event,Http,File}.swift.
 * No mpv writes, shell commands, UI analysis, or media decoding in the plugin.
 */
const { mpv, event, http, file } = iina;
const session = Date.now().toString(36) + "-" + Math.random().toString(36).slice(2);
const configPath = "~/Library/Application Support/SceneHarbor/AutoHDR/iina.json";
let sequence = 0, generation = 0, ended = false, loading = false;
let retryTimer = null, pending = null, sending = false;
let shuttingDown = false;
function read(name) {
  if (shuttingDown || ended) return null;
  try { return mpv.getNative(name); } catch (_) { return null; }
}
function snapshot(name) {
  // end-file/shutdown may arrive after IINA has destroyed its native mpv handle.
  // Never call getNative to report inactivity: a native SIGSEGV cannot be caught.
  if (ended || shuttingDown) return {
    version: 1, session, sequence: ++sequence, event: name,
    active: false, timestamp: Date.now() / 1000
  };
  const tracks = read("track-list") || [];
  const track = tracks.find(t => t.type === "video" && t.selected) || {};
  const params = loading ? {} : (read("video-params") || {});
  const path = read("path") || "";
  return {
    version: 1, session, sequence: ++sequence, event: name,
    active: !ended && !!path && read("idle-active") !== true,
    path, mediaType: track.image === true && track.albumart !== true ? "image" : "video",
    transfer: params.gamma || null, primaries: params.primaries || null,
    sigPeak: params["sig-peak"] || null,
    dolbyVisionProfile: loading ? null : (track["dolby-vision-profile"] || null),
    paused: read("pause") === true, timestamp: Date.now() / 1000
  };
}
function pump() {
  if (shuttingDown || sending || !pending) return;
  const payload = pending; pending = null;
  try {
    if (!file.exists(configPath)) return;
    const config = JSON.parse(file.read(configPath, {}));
    if (typeof config.token !== "string" || config.token.length < 32 || config.port !== 48743) return;
    sending = true;
    // IINA 1.4.4 encodes `data` as a form. JSON is carried in one form field.
    const request = http.post("http://127.0.0.1:48743/auto-hdr/iina", {
      headers: { "Authorization": "Bearer " + config.token },
      data: { payload: JSON.stringify(payload) }
    });
    Promise.resolve(request).then(finish, finish);
  } catch (_) { finish(); }
}
function finish() { sending = false; if (pending) pump(); }
function publish(name) { if (!shuttingDown) { pending = snapshot(name); pump(); } }
function inspect(name, attempt, token) {
  if (shuttingDown || token !== generation || ended) return;
  const value = snapshot(name);
  pending = value; pump();
  if (value.active && !value.transfer && attempt < 3) {
    retryTimer = setTimeout(() => inspect(name, attempt + 1, token), [150, 350, 700][attempt]);
  }
}
function loaded() {
  if (shuttingDown) return;
  ended = false; loading = false; generation++;
  if (retryTimer !== null) clearTimeout(retryTimer);
  const token = generation;
  retryTimer = setTimeout(() => inspect("file-loaded", 0, token), 100);
}
event.on("mpv.start-file", () => {
  if (shuttingDown) return;
  generation++; ended = false; loading = true;
  if (retryTimer !== null) clearTimeout(retryTimer);
  publish("start-file");
});
event.on("mpv.file-loaded", loaded);
event.on("mpv.video-reconfig", () => {
  if (!loading && !ended) inspect("video-reconfig", 0, generation);
});
event.on("mpv.end-file", () => {
  if (shuttingDown) return;
  generation++; ended = true; loading = false;
  if (retryTimer !== null) clearTimeout(retryTimer);
  publish("end-file");
});
event.on("mpv.shutdown", () => {
  shuttingDown = true; ended = true; loading = false; generation++;
  if (retryTimer !== null) clearTimeout(retryTimer);
  clearInterval(heartbeatTimer);
  pending = null;
  // No native reads or new HTTP work during teardown. SceneHarbor clears the
  // demand on end-file, process exit, or the existing bounded heartbeat lease.
});
// Pausing never clears demand. Each player has its own renewable lease.
const heartbeatTimer = setInterval(() => publish("heartbeat"), 2000);
publish("heartbeat");
