'use strict';

const express = require('express');
const { z } = require('zod');
const sources = require('../services/sources');
const { requireAuth } = require('../middleware/auth');
const { validate } = require('../middleware/validate');

const router = express.Router();
router.use(requireAuth);

const createSchema = z.object({
  type: z.string().min(1),
  name: z.string().min(1).max(100),
  config: z.record(z.unknown()).optional(),
  enabled: z.boolean().optional(),
});

const updateSchema = z.object({
  name: z.string().min(1).max(100).optional(),
  config: z.record(z.unknown()).optional(),
  enabled: z.boolean().optional(),
});

router.get('/', (req, res) => res.json({ sources: sources.list(req.auth.userId) }));

router.post('/', validate(createSchema), (req, res, next) => {
  try {
    res.status(201).json(sources.create(req.auth.userId, req.body));
  } catch (error) {
    next(error);
  }
});

router.get('/:id', (req, res, next) => {
  try {
    res.json(sources.get(req.auth.userId, req.params.id));
  } catch (error) {
    next(error);
  }
});

router.patch('/:id', validate(updateSchema), (req, res, next) => {
  try {
    res.json(sources.update(req.auth.userId, req.params.id, req.body));
  } catch (error) {
    next(error);
  }
});

router.delete('/:id', (req, res, next) => {
  try {
    sources.delete(req.auth.userId, req.params.id);
    res.status(204).end();
  } catch (error) {
    next(error);
  }
});

module.exports = router;
