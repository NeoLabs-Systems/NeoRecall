'use strict';

// The day's summary, asked for separately from the consolidation itself.
//
// A long transcript is consolidated in windows, and no single window can see the
// day. Asking whichever window happens to be last to summarise the whole day
// therefore asks it to write about material it was never shown; what came back
// was either a summary of the last few minutes or, often enough, nothing at all
// — and a missing daily summary failed the entire run.
//
// So the day is summarised once, from the finished picture: the titles and
// summaries of the memory-worthy sections the run produced, plus whatever the
// day's summary already said. It is a short request over short input, which is
// also the cheapest thing this pipeline asks of the model.

const INSTRUCTIONS = `You maintain a running summary of one day for a personal memory service. Return one JSON object matching the supplied contract.
You are given the description of the day written so far, if there is one, and the occasions recorded since. Produce the summary of the WHOLE day: carry forward everything the earlier text still says correctly and fold in the new occasions. It replaces the earlier text, so never write it as an addendum, never refer to an update, and never mention that a summary already existed.
Write English prose, even when the occasions came from German or another transcript. Preserve proper names accurately. A few sentences is right: name what actually happened and what was decided, not how many conversations were recorded. Do not invent anything the supplied occasions do not support, and do not restate a calendar date. Return no prose outside JSON.`;

function dailySummaryMessages({ sections, previousDailySummary, timezone }) {
  return [
    { role: 'system', content: INSTRUCTIONS },
    {
      role: 'user',
      content: JSON.stringify({
        timezone,
        describedSoFar: previousDailySummary ? previousDailySummary.summary_en : null,
        occasions: sections.map((section) => ({
          titleEn: section.titleEn,
          summaryEn: section.summaryEn,
          topics: section.topics,
        })),
        outputContract: { summaryEn: 'English summary of the whole day' },
      }),
    },
  ];
}

module.exports = { dailySummaryMessages };
