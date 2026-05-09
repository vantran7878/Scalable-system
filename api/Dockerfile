FROM node:18-alpine

WORKDIR /app

# Install dependencies first (layer cache friendly)
COPY package*.json ./
RUN npm install --production --silent

# Copy source
COPY index.js .

EXPOSE 3000

CMD ["node", "index.js"]
