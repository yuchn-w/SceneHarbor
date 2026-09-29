const fs = require('fs'), vm = require('vm'), assert = require('assert');
let properties = {}, callbacks = {}, timers = [], sent = [];
let nativeReads = 0, intervalCleared = false;
const context = {
  iina: {
    mpv: {getNative: key => {nativeReads++; return properties[key];}},
    event: {on: (key, fn) => {callbacks[key] = fn;}},
    file: {exists: () => true, read: () => JSON.stringify({port: 48743, token: 'x'.repeat(64)})},
    http: {post: (url, options) => { sent.push(JSON.parse(options.data.payload)); return Promise.resolve({}); }}
  },
  setTimeout: fn => {timers.push(fn); return timers.length;}, clearTimeout: () => {},
  setInterval: fn => {context.heartbeat = fn; return 99;},
  clearInterval: id => {assert.equal(id, 99); intervalCleared = true;}, Date, Math, Promise
};
vm.createContext(context);
vm.runInContext(fs.readFileSync(process.argv[2] || 'Integrations/IINA/SceneHarborHDR/main.js', 'utf8'), context);
async function flush() { for (let i=0;i<6;i++) await Promise.resolve(); }
(async () => {
  await flush(); sent = [];
  properties = {path: '/tmp/movie.mkv', 'idle-active': false, 'track-list': [{type:'video',selected:true}], 'video-params': {gamma:'pq',primaries:'bt.2020'}};
  callbacks['mpv.start-file'](); await flush();
  assert.equal(sent.at(-1).transfer, null);
  callbacks['mpv.file-loaded'](); timers.shift()(); await flush();
  assert.equal(sent.at(-1).transfer, 'pq'); assert(sent.at(-1).active);
  properties.pause = true; context.heartbeat(); await flush();
  assert(sent.at(-1).active && sent.at(-1).paused);
  const readsBeforeEnd = nativeReads;
  callbacks['mpv.end-file'](); await flush(); assert(!sent.at(-1).active);
  context.heartbeat(); await flush(); assert(!sent.at(-1).active);
  assert.equal(nativeReads, readsBeforeEnd, 'end-file and idle heartbeats must not touch mpv');
  properties['track-list'][0].image = true;
  callbacks['mpv.file-loaded'](); timers.shift()(); await flush();
  assert.equal(sent.at(-1).mediaType, 'image');
  properties['video-params'] = {}; callbacks['mpv.file-loaded']();
  let tries = 0; while (timers.length) {timers.shift()(); tries++; await flush();}
  assert.equal(tries, 4); assert.equal(sent.at(-1).transfer, null);
  context.iina.http.post = () => Promise.reject(new Error('SceneHarbor stopped'));
  context.heartbeat(); await flush(); context.heartbeat(); await flush();
  context.iina.file.exists = () => false; context.heartbeat(); await flush();
  // A request is still in flight when native mpv is destroyed. Queued retries,
  // events and even an already-enqueued heartbeat must all become inert.
  context.iina.file.exists = () => true;
  let resolveRequest;
  context.iina.http.post = (url, options) => {
    sent.push(JSON.parse(options.data.payload));
    return new Promise(resolve => {resolveRequest = resolve;});
  };
  context.heartbeat(); context.heartbeat();
  callbacks['mpv.file-loaded']();
  const readsBeforeShutdown = nativeReads, sendsBeforeShutdown = sent.length;
  callbacks['mpv.shutdown']();
  assert(intervalCleared);
  context.heartbeat();
  for (const name of ['mpv.start-file','mpv.file-loaded','mpv.video-reconfig','mpv.end-file','mpv.shutdown']) callbacks[name]();
  while (timers.length) timers.shift()();
  resolveRequest({}); await flush();
  assert.equal(nativeReads, readsBeforeShutdown, 'shutdown must never call native mpv');
  assert.equal(sent.length, sendsBeforeShutdown, 'shutdown must discard queued HTTP work');
  console.log('PASS shutdown: no native reads, timers stopped, late events/retries/HTTP completion inert');
  console.log('PASS IINA plugin: real-property snapshots, events, pause, images, bounded retry, offline failure');
})().catch(e => {console.error(e); process.exitCode=1;});
