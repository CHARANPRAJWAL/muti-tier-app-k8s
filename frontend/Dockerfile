FROM node:18-alpine

WORKDIR /app

COPY package*.json ./

RUN npm i

COPY . .

ENV REACT_APP_API_URL=/api

RUN npm run build

RUN npm install -g serve

ENV NODE_ENV=production

EXPOSE 3000

USER node

CMD ["serve", "-s", "build", "-l", "3000"]
