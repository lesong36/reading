/**
 * Reading Explorer Foundations (3rd ed.) Reading Comprehension A answer keys.
 * Transcribed from the supplied "f级答案.pdf" answer book on 2026-08-08.
 * Values are zero-based option indexes; absent indexes are intentionally not
 * graded because the corresponding PPT question was malformed on extraction.
 */
const indexes = (letters) => Object.fromEntries(Object.entries(letters)
  .map(([number, answer]) => [Number(number), 'abcd'.indexOf(answer)]));

export const reFoundationsAnswerKeys = {
  're-foundations-1a-a-mysterious-visitor': indexes({ 1: 'c', 2: 'a', 3: 'c', 4: 'b', 5: 'c' }),
  're-foundations-1b-the-lost-city-of-atlantis': indexes({ 1: 'b', 2: 'c', 3: 'c', 4: 'b', 5: 'c' }),
  're-foundations-2a-the-world-of-speed-eating': indexes({ 1: 'c', 2: 'a', 3: 'a', 4: 'a', 5: 'b' }),
  're-foundations-2b-the-hottest-chilies': indexes({ 1: 'b', 2: 'c', 3: 'a', 4: 'a', 5: 'c' }),
  're-foundations-3a-digging-for-the-past': indexes({ 1: 'a', 2: 'c', 3: 'c', 4: 'b', 5: 'b' }),
  're-foundations-3b-an-interview-with-joel-sartore': indexes({ 1: 'b', 2: 'a', 3: 'c', 4: 'c', 5: 'c' }),
  're-foundations-4a-i-ve-found-the-titanic': indexes({ 1: 'c', 2: 'a', 3: 'b', 5: 'b', 6: 'a' }),
  're-foundations-4b-my-descent-into-the-titanic': indexes({ 1: 'c', 2: 'b', 3: 'c', 4: 'c', 5: 'a' }),
  're-foundations-5a-the-disease-detective': indexes({ 1: 'b', 2: 'a', 3: 'c', 4: 'b', 5: 'c' }),
  're-foundations-5b-at-the-crime-scene': indexes({ 1: 'b', 2: 'b', 3: 'b', 4: 'b', 5: 'a' }),
  're-foundations-6a-planting-for-the-planet': indexes({ 1: 'c', 2: 'b', 3: 'c', 4: 'a', 5: 'b' }),
  're-foundations-6b-fatal-attraction': indexes({ 1: 'a', 2: 'c', 3: 'a', 4: 'a', 5: 'c' }),
  're-foundations-7a-understanding-dreams': indexes({ 1: 'c', 2: 'c', 3: 'a', 4: 'c', 5: 'a' }),
  're-foundations-7b-seeing-the-impossible': indexes({ 1: 'c', 2: 'c', 3: 'a', 4: 'b', 5: 'b' }),
  're-foundations-8a-a-penguin-s-year': indexes({ 1: 'a', 2: 'c', 3: 'a', 4: 'b', 5: 'a' }),
  're-foundations-8b-do-animals-laugh': indexes({ 1: 'b', 2: 'c', 3: 'c', 4: 'c', 5: 'b' }),
  're-foundations-9a-a-love-poem-in-stone': indexes({ 1: 'b', 2: 'c', 3: 'b', 4: 'a', 5: 'b' }),
  're-foundations-9b-the-great-dome-of-florence': indexes({ 1: 'a', 2: 'b', 3: 'b', 4: 'b', 5: 'a' }),
  're-foundations-10a-wild-weather': indexes({ 1: 'b', 2: 'a', 3: 'b', 4: 'b', 5: 'b' }),
  're-foundations-10b-when-weird-weather-strikes': indexes({ 1: 'c', 2: 'a', 3: 'b', 4: 'a', 5: 'c' }),
  're-foundations-11a-the-mammoth-s-tale': indexes({ 1: 'b', 2: 'a', 3: 'b', 4: 'c', 5: 'c' }),
  're-foundations-11b-giants-of-the-past': indexes({ 1: 'a', 2: 'b', 3: 'b', 4: 'c', 5: 'c' }),
  're-foundations-12a-the-robots-are-coming': indexes({ 1: 'a', 2: 'b', 3: 'b', 4: 'a', 5: 'c' }),
  're-foundations-12b-how-will-we-live-in-2045': indexes({ 1: 'a', 2: 'b', 3: 'b', 4: 'c', 5: 'b' })
};
