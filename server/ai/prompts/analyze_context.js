'use strict';

function outputContract() {
  return { descriptionEn: 'Faithful concise English description of the supplied source.' };
}

function textMessages({ name, content }) {
  return [
    { role: 'system', content: 'You describe user-supplied context for a personal memory. Return one JSON object matching the contract. Preserve names, numbers, decisions, action items, and qualifications accurately. A document may describe plans rather than events that happened; never present planned material as completed. Return no prose outside JSON.' },
    { role: 'user', content: JSON.stringify({ sourceName: name, content, outputContract: outputContract() }) },
  ];
}

function imageMessages({ name, mediaType, data }) {
  return [
    { role: 'system', content: 'You describe a user-supplied image for a personal memory. Return one JSON object matching the contract. Describe visible facts and transcribe important visible text faithfully. Do not infer identities or events the image does not establish. Return no prose outside JSON.' },
    { role: 'user', content: [
      { type: 'text', text: JSON.stringify({ sourceName: name, outputContract: outputContract() }) },
      { type: 'input_image', mediaType, data },
    ] },
  ];
}

const responseFormat = {
  type: 'json_schema',
  json_schema: {
    name: 'neorecall_context_analysis', strict: true,
    schema: {
      type: 'object', additionalProperties: false, required: ['descriptionEn'],
      properties: { descriptionEn: { type: 'string', minLength: 1 } },
    },
  },
};

module.exports = { textMessages, imageMessages, responseFormat };
