FROM node:22-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY src ./src
COPY lua ./lua
COPY config ./config
COPY dashboard ./dashboard
COPY bench/mock-upstream.js ./bench/mock-upstream.js
EXPOSE 3000
CMD ["node", "src/index.js"]
