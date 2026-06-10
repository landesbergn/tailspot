import { buildApp } from "./app.js";

const PORT = Number(process.env.PORT ?? 8080);
const HOST = "0.0.0.0";

const app = await buildApp();

try {
  await app.listen({ port: PORT, host: HOST });
  // Fastify logs the address automatically when logger is enabled.
} catch (err) {
  app.log.error(err);
  process.exit(1);
}
