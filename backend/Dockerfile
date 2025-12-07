FROM node:18-alpine

WORKDIR /app

COPY package*.json ./

RUN npm ci --only=production

COPY . .

# Fix permissions so the "node" user can read files
RUN chown -R node:node /app

USER node

ENV NODE_ENV=production
EXPOSE 5000

CMD ["node", "server.js"]
