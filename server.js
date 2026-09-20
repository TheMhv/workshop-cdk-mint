require('dotenv').config();
const fs = require('fs');
const path = require('path');
const express = require('express');
const { authenticatedLndGrpc, pay, decodePaymentRequest, getInvoice, createInvoice } = require('lightning');

const PORT = process.env.PORT || 3000;
const SOCKET = process.env.LND_SOCKET;
const CERT_PATH = process.env.LND_CERT_PATH;
const MACAROON_PATH = process.env.LND_MACAROON_PATH;
// Maximum amount (in sats) allowed when creating an invoice. Override with MAX_INVOICE_SATS in .env
const MAX_INVOICE_SATS = Number(process.env.MAX_INVOICE_SATS) || 1000;

if (!SOCKET || !CERT_PATH || !MACAROON_PATH) {
  console.error('Missing LND_SOCKET, LND_CERT_PATH or LND_MACAROON_PATH in .env');
  process.exit(1);
}

// lightning wants the cert/macaroon base64-encoded; read the raw files and encode them.
const cert = fs.readFileSync(CERT_PATH).toString('base64');
const macaroon = fs.readFileSync(MACAROON_PATH).toString('base64');

const { lnd } = authenticatedLndGrpc({ cert, macaroon, socket: SOCKET });

const PUBLIC_DIR = path.join(__dirname, 'public');
const INDEX_HTML = path.join(PUBLIC_DIR, 'index.html');
if (!fs.existsSync(INDEX_HTML)) {
  console.error(`Cannot find ${INDEX_HTML}`);
  console.error('Make sure the "public" folder sits next to server.js, containing index.html.');
  process.exit(1);
}

const app = express();
app.use(express.json());
app.use(express.static(PUBLIC_DIR));
app.get('/', (req, res) => res.sendFile(INDEX_HTML));

// Let the UI know the invoice limit
app.get('/api/config', (req, res) => {
  res.json({ max_invoice_sats: MAX_INVOICE_SATS });
});

// Decode a BOLT11 payment request
app.post('/api/decode', async (req, res) => {
  try {
    const { request } = req.body;
    if (!request) return res.status(400).json({ error: 'Missing "request".' });
    const d = await decodePaymentRequest({ lnd, request });
    res.json({
      destination: d.destination,
      payment_hash: d.id,
      sats: d.tokens,
      description: d.description || null,
      created_at: d.created_at,
      expires_at: d.expires_at,
    });
  } catch (err) {
    res.status(500).json({ error: err.message || String(err) });
  }
});

// Look up an invoice you created, by payment hash (hex)
app.get('/api/invoice/:hash', async (req, res) => {
  try {
    const id = req.params.hash;
    const inv = await getInvoice({ lnd, id });
    res.json({
      is_confirmed: inv.is_confirmed,
      sats_received: inv.received,
      sats_requested: inv.tokens,
      description: inv.description || null,
      confirmed_at: inv.confirmed_at || null,
    });
  } catch (err) {
    res.status(500).json({ error: err.message || String(err) });
  }
});

// Pay a BOLT11 payment request
app.post('/api/pay', async (req, res) => {
  try {
    const { request, amt } = req.body;
    if (!request) return res.status(400).json({ error: 'Missing "request".' });
    const args = { lnd, request };
    if (amt) args.tokens = Number(amt);
    const result = await pay(args);
    res.json({
      payment_hash: result.id,
      preimage: result.secret,
      fee_sats: result.fee,
      sats_paid: result.tokens,
    });
  } catch (err) {
    res.status(500).json({ error: err.message || String(err) });
  }
});

// Create a new invoice to receive a payment
app.post('/api/create-invoice', async (req, res) => {
  try {
    const { amt, description, expires_in_seconds } = req.body;
    const args = { lnd };
    // Require a valid amount, capped at MAX_INVOICE_SATS (also blocks open-amount invoices)
    const tokens = Number(amt);
    if (!Number.isInteger(tokens) || tokens <= 0) {
      return res.status(400).json({ error: 'Amount must be a positive whole number of sats.' });
    }
    if (tokens > MAX_INVOICE_SATS) {
      return res.status(400).json({ error: `Amount exceeds the limit of ${MAX_INVOICE_SATS} sats.` });
    }
    args.tokens = tokens;
    if (description) args.description = description;
    if (expires_in_seconds) args.expires_at = new Date(Date.now() + Number(expires_in_seconds) * 1000).toISOString();
    const inv = await createInvoice(args);
    res.json({
      request: inv.request,
      payment_hash: inv.id,
      sats: inv.tokens,
      created_at: inv.created_at,
      expires_at: inv.expires_at,
    });
  } catch (err) {
    res.status(500).json({ error: err.message || String(err) });
  }
});

app.listen(PORT, () => {
  console.log(`LND Invoice Tool running at http://localhost:${PORT}`);
});
