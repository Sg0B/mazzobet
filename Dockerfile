# MazzoBet: un solo contenitore con il server Node che serve anche il frontend compilato.
# Costruzione in tre passi: frontend (Vite), server (TypeScript), immagine finale leggera.

FROM node:22-alpine AS web
WORKDIR /app/web
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
RUN npm run build

FROM node:22-alpine AS server
WORKDIR /app/server
COPY server/package.json server/package-lock.json ./
RUN npm ci
COPY server/ ./
RUN npm run build && npm prune --omit=dev

FROM node:22-alpine
ENV NODE_ENV=production PORT=3000 STATIC_DIR=/app/web/dist
WORKDIR /app/server
COPY --from=server /app/server/node_modules ./node_modules
COPY --from=server /app/server/dist ./dist
COPY --from=server /app/server/data ./data
COPY --from=server /app/server/package.json ./package.json
COPY --from=web /app/web/dist /app/web/dist
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s CMD wget -qO- http://127.0.0.1:3000/api/health || exit 1
# Le variabili (SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY) arrivano dal file .env del VPS, mai dentro l'immagine.
CMD ["node", "dist/index.js"]
