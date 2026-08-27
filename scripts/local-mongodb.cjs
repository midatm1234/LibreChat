const fs = require('fs');
const path = require('path');
const { MongoMemoryServer } = require('mongodb-memory-server');

const root = path.resolve(__dirname, '..');
const dbPath = path.join(root, '.local', 'mongodb-data');

fs.mkdirSync(dbPath, { recursive: true });

async function start() {
  const server = await MongoMemoryServer.create({
    instance: {
      port: 27017,
      dbPath,
      storageEngine: 'wiredTiger',
    },
  });

  console.log(`Local MongoDB ready at ${server.getUri()}`);

  const stop = async () => {
    await server.stop();
    process.exit(0);
  };

  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}

start().catch((error) => {
  console.error(error);
  process.exit(1);
});
