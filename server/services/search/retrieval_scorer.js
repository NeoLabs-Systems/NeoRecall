'use strict';

function exponentialRecency(occurredAt, now, halfLifeDays) {
  const ageDays = Math.max(0, (now.getTime() - new Date(occurredAt).getTime()) / 86_400_000);
  return Math.exp(-Math.log(2) * ageDays / halfLifeDays);
}

function score({ relevance, occurredAt, importance }, config, now = new Date()) {
  const normalizedImportance = Math.max(0, Math.min(1, Number(importance || 0) / 10));
  const recency = exponentialRecency(occurredAt, now, config.searchHalfLifeDays);
  return config.searchWeights.relevance * relevance + config.searchWeights.recency * recency + config.searchWeights.importance * normalizedImportance;
}

module.exports = { exponentialRecency, score };
