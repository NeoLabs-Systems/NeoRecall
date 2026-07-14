'use strict';

const { HttpError } = require('./error_handler');

function validate(schema, location = 'body') {
  return (req, _res, next) => {
    const parsed = schema.safeParse(req[location]);
    if (!parsed.success) {
      return next(new HttpError(400, 'VALIDATION_ERROR', 'The request is invalid.', parsed.error.flatten()));
    }
    req[location] = parsed.data;
    return next();
  };
}

module.exports = { validate };
