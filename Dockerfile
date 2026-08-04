FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM node:20-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY --from=deps /app/node_modules ./node_modules
COPY package.json package-lock.json ./
COPY src ./src
COPY bin ./bin
RUN chmod +x bin/* && touch /.dockerenv
USER node
EXPOSE 3000
CMD ["node", "src/000.js"]
