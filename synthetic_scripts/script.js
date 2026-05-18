/**
 * New Relic Scripted API Monitor
 * 
 * Reads base64 cert/key from Secure Credentials
 * Decodes to PEM in-memory, connects to EC2 via mTLS
 */

const got   = require('got');
const https = require('https');

const ENDPOINT = 'https://YOUR_EC2_IP/health';

// Decode base64 → PEM string (no disk writes needed)
const certPEM = Buffer.from($secure.NR_CLIENT_CERT, 'base64').toString('utf8');
const keyPEM  = Buffer.from($secure.NR_CLIENT_KEY,  'base64').toString('utf8');

const agent = new https.Agent({
  cert: certPEM,
  key:  keyPEM,
  rejectUnauthorized: false, // set true if EC2 has a CA-signed server cert
});

const client = got.extend({
  agent:        { https: agent },
  timeout:      { request: 10_000 },
  retry:        { limit: 0 },
  responseType: 'json',
});

(async () => {
  const start = Date.now();
  try {
    const res = await client.get(ENDPOINT);
    console.log(`Authenticated | ${res.statusCode} | ${Date.now() - start}ms`);
    console.log('Response:', JSON.stringify(res.body));
  } catch (err) {
    const status = err.response?.statusCode ?? 'no-response';
    throw new Error(`Auth failed [${status}]: ${err.message}`);
  }
})();