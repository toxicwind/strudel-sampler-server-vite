import express from 'express';
import fs from 'fs';
import path from 'path';
import mm from 'music-metadata';

const app = express();
const PORT = parseInt(process.env.PORT || '5432', 10);
const SAMPLE_ROOT = process.env.STRUDEL_SAMPLES || path.join(process.env.HOME || '', 'strudel-dev', 'samples');

function isAudio(file: string) {
  return ['.mp3','.wav','.ogg','.flac','.m4a','.aiff'].includes(path.extname(file).toLowerCase());
}

async function scan(root: string) {
  const out: Record<string,string> = {};
  const walk = (d: string) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const full = path.join(d, e.name);
      if (e.isDirectory()) walk(full);
      else if (e.isFile() && isAudio(full)) {
        const key = path.basename(full).replace(/\s+/g,'_').replace(/[^a-zA-Z0-9_\.-]/g,'').toLowerCase();
        out[key.replace(path.extname(key), '')] = path.relative(SAMPLE_ROOT, full);
      }
    }
  };
  walk(root);
  return out;
}

app.get('/', async (_req, res) => {
  const map = await scan(SAMPLE_ROOT);
  res.json({ _base: `http://localhost:${PORT}/files/`, ...map });
});

app.get('/files/*', (req, res) => {
  const rel = req.params[0];
  const full = path.join(SAMPLE_ROOT, rel);
  if (!full.startsWith(SAMPLE_ROOT)) return res.status(403).json({ error: 'Access denied' });
  if (!fs.existsSync(full)) return res.status(404).json({ error: 'Not found' });
  res.setHeader('Accept-Ranges', 'bytes');
  fs.createReadStream(full).pipe(res);
});

app.get('/stats', async (_req, res) => {
  const map = await scan(SAMPLE_ROOT);
  res.json({ total: Object.keys(map).length, root: SAMPLE_ROOT, port: PORT });
});

app.listen(PORT, () => console.log(`[sampler] http://localhost:${PORT}`));
