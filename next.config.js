// module.exports = {
//   i18n: {
//     locales: ['ru', 'en', 'fr'],
//     defaultLocale: 'ru',
//   },
// }
const nextTranslate = require('next-translate')

module.exports = {
  ...nextTranslate(),
};

