'use strict';

const express = require('express');
const service = require('../services/recordings/recording_service');
const { requireAuth, requireScope } = require('../middleware/auth');
const router = express.Router();
router.use(requireAuth);
router.get('/', requireScope('recordings:read'), (req, res) => res.json(service.list(req.auth.userId, req.query)));
router.get('/:id/transcript', requireScope('recordings:read'), (req, res, next) => { try { res.json(service.transcript(req.auth.userId, req.params.id, req.query)); } catch (error) { next(error); } });
router.get('/:id', requireScope('recordings:read'), (req, res, next) => { try { res.json(service.get(req.auth.userId, req.params.id)); } catch (error) { next(error); } });
router.delete('/:id', requireScope('recordings:write'), (req, res, next) => { try { service.remove(req.auth.userId, req.params.id); res.status(204).end(); } catch (error) { next(error); } });
module.exports = router;
