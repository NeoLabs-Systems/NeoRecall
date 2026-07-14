'use strict';

function cors(req, res, next) {
  const origin = req.get('Origin');
  const configured = (process.env.NEORECALL_ALLOWED_ORIGINS || '').split(',').map((value) => value.trim()).filter(Boolean);
  if (origin && (configured.includes(origin) || configured.includes('*'))) {
    res.set('Access-Control-Allow-Origin', origin);
    res.set('Vary', 'Origin');
    res.set('Access-Control-Allow-Headers', 'Authorization,Content-Type,Idempotency-Key,X-Chunk-Sha256,X-Chunk-Duration-Ms,X-Chunk-Overlap-Ms,X-Channel-Layout,X-Monotonic-Offset-Ms,X-Device-Started-At,X-Audio-Container,X-Audio-Codec,X-Final-Chunk,Content-Range,X-Part-Sha256');
    res.set('Access-Control-Allow-Methods', 'GET,POST,PUT,PATCH,DELETE,OPTIONS');
  }
  if (req.method === 'OPTIONS') return res.status(204).end();
  return next();
}

module.exports = { cors };
