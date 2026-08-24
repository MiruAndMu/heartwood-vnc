const assert = require('node:assert/strict');
const { app, safeStorage } = require('electron');

app.whenReady().then(() => {
  const sentinel = 'heartwood-qa-sentinel';
  assert.equal(safeStorage.isEncryptionAvailable(), true,
               'Electron safeStorage encryption is unavailable');
  const encrypted = safeStorage.encryptString(sentinel);
  assert.ok(Buffer.isBuffer(encrypted));
  assert.notEqual(encrypted.toString('utf8'), sentinel);
  assert.equal(safeStorage.decryptString(encrypted), sentinel);
  console.log(JSON.stringify({ safeStorage: 'available', roundTrip: 'passed' }));
  app.quit();
}).catch((error) => {
  console.error(error);
  app.exit(1);
});
