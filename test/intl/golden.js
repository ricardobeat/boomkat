// Prints every string the English Intl services can produce, one per line.
// `just intl-golden` compares the output with golden.txt.gz. The snapshot
// includes historical second-resolution zone offsets and retained zone aliases;
// encoding changes must leave the output byte-identical.
// The lists are the keys of the generated tables in src/builtins/intl_*_data.c3.
var CURRENCIES = ["ADP", "AED", "AFA", "AFN", "ALK", "ALL", "AMD", "ANG", "AOA", "AOK", "AON", "AOR", "ARA", "ARL", "ARM", "ARP", "ARS", "ATS", "AUD", "AWG", "AZM", "AZN", "BAD", "BAM", "BAN", "BBD", "BDT", "BEC", "BEF", "BEL", "BGL", "BGM", "BGN", "BGO", "BHD", "BIF", "BMD", "BND", "BOB", "BOL", "BOP", "BOV", "BRB", "BRC", "BRE", "BRL", "BRN", "BRR", "BRZ", "BSD", "BTN", "BUK", "BWP", "BYB", "BYN", "BYR", "BZD", "CAD", "CDF", "CHE", "CHF", "CHW", "CLE", "CLF", "CLP", "CNH", "CNX", "CNY", "COP", "COU", "CRC", "CSD", "CSK", "CUC", "CUP", "CVE", "CYP", "CZK", "DDM", "DEM", "DJF", "DKK", "DOP", "DZD", "ECS", "ECV", "EEK", "EGP", "ERN", "ESA", "ESB", "ESP", "ETB", "EUR", "FIM", "FJD", "FKP", "FRF", "GBP", "GEK", "GEL", "GHC", "GHS", "GIP", "GMD", "GNF", "GNS", "GQE", "GRD", "GTQ", "GWE", "GWP", "GYD", "HKD", "HNL", "HRD", "HRK", "HTG", "HUF", "IDR", "IEP", "ILP", "ILR", "ILS", "INR", "IQD", "IRR", "ISJ", "ISK", "ITL", "JMD", "JOD", "JPY", "KES", "KGS", "KHR", "KMF", "KPW", "KRH", "KRO", "KRW", "KWD", "KYD", "KZT", "LAK", "LBP", "LKR", "LRD", "LSL", "LTL", "LTT", "LUC", "LUF", "LUL", "LVL", "LVR", "LYD", "MAD", "MAF", "MCF", "MDC", "MDL", "MGA", "MGF", "MKD", "MKN", "MLF", "MMK", "MNT", "MOP", "MRO", "MRU", "MTL", "MTP", "MUR", "MVP", "MVR", "MWK", "MXN", "MXP", "MXV", "MYR", "MZE", "MZM", "MZN", "NAD", "NGN", "NIC", "NIO", "NLG", "NOK", "NPR", "NZD", "OMR", "PAB", "PEI", "PEN", "PES", "PGK", "PHP", "PKR", "PLN", "PLZ", "PTE", "PYG", "QAR", "RHD", "ROL", "RON", "RSD", "RUB", "RUR", "RWF", "SAR", "SBD", "SCR", "SDD", "SDG", "SDP", "SEK", "SGD", "SHP", "SIT", "SKK", "SLE", "SLL", "SOS", "SRD", "SRG", "SSP", "STD", "STN", "SUR", "SVC", "SYP", "SZL", "THB", "TJR", "TJS", "TMM", "TMT", "TND", "TOP", "TPE", "TRL", "TRY", "TTD", "TWD", "TZS", "UAH", "UAK", "UGS", "UGX", "USD", "USN", "USS", "UYI", "UYP", "UYU", "UYW", "UZS", "VEB", "VED", "VEF", "VES", "VND", "VNN", "VUV", "WST", "XAF", "XAG", "XAU", "XBA", "XBB", "XBC", "XBD", "XCD", "XCG", "XDR", "XEU", "XFO", "XFU", "XOF", "XPD", "XPF", "XPT", "XRE", "XSU", "XTS", "XUA", "XXX", "YDD", "YER", "YUD", "YUM", "YUN", "YUR", "ZAL", "ZAR", "ZMK", "ZMW", "ZRN", "ZRZ", "ZWD", "ZWG", "ZWL", "ZWR"];
var UNITS = ["acre", "bit", "byte", "celsius", "centimeter", "day", "degree", "fahrenheit", "fluid-ounce", "foot", "gallon", "gigabit", "gigabyte", "gram", "hectare", "hour", "inch", "kilobit", "kilobyte", "kilogram", "kilometer", "liter", "megabit", "megabyte", "meter", "microsecond", "mile", "mile-scandinavian", "milliliter", "millimeter", "millisecond", "minute", "month", "nanosecond", "ounce", "percent", "petabyte", "pound", "second", "stone", "terabit", "terabyte", "week", "yard", "year"];
var ZONES = ["Africa/Abidjan", "Africa/Accra", "Africa/Addis_Ababa", "Africa/Algiers", "Africa/Asmera", "Africa/Bamako", "Africa/Bangui", "Africa/Banjul", "Africa/Bissau", "Africa/Blantyre", "Africa/Brazzaville", "Africa/Bujumbura", "Africa/Cairo", "Africa/Casablanca", "Africa/Ceuta", "Africa/Conakry", "Africa/Dakar", "Africa/Dar_es_Salaam", "Africa/Djibouti", "Africa/Douala", "Africa/El_Aaiun", "Africa/Freetown", "Africa/Gaborone", "Africa/Harare", "Africa/Johannesburg", "Africa/Juba", "Africa/Kampala", "Africa/Khartoum", "Africa/Kigali", "Africa/Kinshasa", "Africa/Lagos", "Africa/Libreville", "Africa/Lome", "Africa/Luanda", "Africa/Lubumbashi", "Africa/Lusaka", "Africa/Malabo", "Africa/Maputo", "Africa/Maseru", "Africa/Mbabane", "Africa/Mogadishu", "Africa/Monrovia", "Africa/Nairobi", "Africa/Ndjamena", "Africa/Niamey", "Africa/Nouakchott", "Africa/Ouagadougou", "Africa/Porto-Novo", "Africa/Sao_Tome", "Africa/Tripoli", "Africa/Tunis", "Africa/Windhoek", "America/Adak", "America/Anchorage", "America/Anguilla", "America/Antigua", "America/Araguaina", "America/Argentina/La_Rioja", "America/Argentina/Rio_Gallegos", "America/Argentina/Salta", "America/Argentina/San_Juan", "America/Argentina/San_Luis", "America/Argentina/Tucuman", "America/Argentina/Ushuaia", "America/Aruba", "America/Asuncion", "America/Bahia", "America/Bahia_Banderas", "America/Barbados", "America/Belem", "America/Belize", "America/Blanc-Sablon", "America/Boa_Vista", "America/Bogota", "America/Boise", "America/Buenos_Aires", "America/Cambridge_Bay", "America/Campo_Grande", "America/Cancun", "America/Caracas", "America/Catamarca", "America/Cayenne", "America/Cayman", "America/Chicago", "America/Chihuahua", "America/Ciudad_Juarez", "America/Coral_Harbour", "America/Cordoba", "America/Costa_Rica", "America/Coyhaique", "America/Creston", "America/Cuiaba", "America/Curacao", "America/Danmarkshavn", "America/Dawson", "America/Dawson_Creek", "America/Denver", "America/Detroit", "America/Dominica", "America/Edmonton", "America/Eirunepe", "America/El_Salvador", "America/Fort_Nelson", "America/Fortaleza", "America/Glace_Bay", "America/Godthab", "America/Goose_Bay", "America/Grand_Turk", "America/Grenada", "America/Guadeloupe", "America/Guatemala", "America/Guayaquil", "America/Guyana", "America/Halifax", "America/Havana", "America/Hermosillo", "America/Indiana/Knox", "America/Indiana/Marengo", "America/Indiana/Petersburg", "America/Indiana/Tell_City", "America/Indiana/Vevay", "America/Indiana/Vincennes", "America/Indiana/Winamac", "America/Indianapolis", "America/Inuvik", "America/Iqaluit", "America/Jamaica", "America/Jujuy", "America/Juneau", "America/Kentucky/Monticello", "America/Kralendijk", "America/La_Paz", "America/Lima", "America/Los_Angeles", "America/Louisville", "America/Lower_Princes", "America/Maceio", "America/Managua", "America/Manaus", "America/Marigot", "America/Martinique", "America/Matamoros", "America/Mazatlan", "America/Mendoza", "America/Menominee", "America/Merida", "America/Metlakatla", "America/Mexico_City", "America/Miquelon", "America/Moncton", "America/Monterrey", "America/Montevideo", "America/Montserrat", "America/Nassau", "America/New_York", "America/Nome", "America/Noronha", "America/North_Dakota/Beulah", "America/North_Dakota/Center", "America/North_Dakota/New_Salem", "America/Ojinaga", "America/Panama", "America/Paramaribo", "America/Phoenix", "America/Port-au-Prince", "America/Port_of_Spain", "America/Porto_Velho", "America/Puerto_Rico", "America/Punta_Arenas", "America/Rankin_Inlet", "America/Recife", "America/Regina", "America/Resolute", "America/Rio_Branco", "America/Santarem", "America/Santiago", "America/Santo_Domingo", "America/Sao_Paulo", "America/Scoresbysund", "America/Sitka", "America/St_Barthelemy", "America/St_Johns", "America/St_Kitts", "America/St_Lucia", "America/St_Thomas", "America/St_Vincent", "America/Swift_Current", "America/Tegucigalpa", "America/Thule", "America/Tijuana", "America/Toronto", "America/Tortola", "America/Vancouver", "America/Whitehorse", "America/Winnipeg", "America/Yakutat", "Antarctica/Casey", "Antarctica/Davis", "Antarctica/DumontDUrville", "Antarctica/Macquarie", "Antarctica/Mawson", "Antarctica/McMurdo", "Antarctica/Palmer", "Antarctica/Rothera", "Antarctica/Syowa", "Antarctica/Troll", "Antarctica/Vostok", "Arctic/Longyearbyen", "Asia/Aden", "Asia/Almaty", "Asia/Amman", "Asia/Anadyr", "Asia/Aqtau", "Asia/Aqtobe", "Asia/Ashgabat", "Asia/Atyrau", "Asia/Baghdad", "Asia/Bahrain", "Asia/Baku", "Asia/Bangkok", "Asia/Barnaul", "Asia/Beirut", "Asia/Bishkek", "Asia/Brunei", "Asia/Calcutta", "Asia/Chita", "Asia/Colombo", "Asia/Damascus", "Asia/Dhaka", "Asia/Dili", "Asia/Dubai", "Asia/Dushanbe", "Asia/Famagusta", "Asia/Gaza", "Asia/Hebron", "Asia/Hong_Kong", "Asia/Hovd", "Asia/Irkutsk", "Asia/Jakarta", "Asia/Jayapura", "Asia/Jerusalem", "Asia/Kabul", "Asia/Kamchatka", "Asia/Karachi", "Asia/Katmandu", "Asia/Khandyga", "Asia/Krasnoyarsk", "Asia/Kuala_Lumpur", "Asia/Kuching", "Asia/Kuwait", "Asia/Macau", "Asia/Magadan", "Asia/Makassar", "Asia/Manila", "Asia/Muscat", "Asia/Nicosia", "Asia/Novokuznetsk", "Asia/Novosibirsk", "Asia/Omsk", "Asia/Oral", "Asia/Phnom_Penh", "Asia/Pontianak", "Asia/Pyongyang", "Asia/Qatar", "Asia/Qostanay", "Asia/Qyzylorda", "Asia/Rangoon", "Asia/Riyadh", "Asia/Saigon", "Asia/Sakhalin", "Asia/Samarkand", "Asia/Seoul", "Asia/Shanghai", "Asia/Singapore", "Asia/Srednekolymsk", "Asia/Taipei", "Asia/Tashkent", "Asia/Tbilisi", "Asia/Tehran", "Asia/Thimphu", "Asia/Tokyo", "Asia/Tomsk", "Asia/Ulaanbaatar", "Asia/Ust-Nera", "Asia/Vientiane", "Asia/Vladivostok", "Asia/Yakutsk", "Asia/Yekaterinburg", "Asia/Yerevan", "Atlantic/Azores", "Atlantic/Bermuda", "Atlantic/Canary", "Atlantic/Cape_Verde", "Atlantic/Faeroe", "Atlantic/Madeira", "Atlantic/Reykjavik", "Atlantic/South_Georgia", "Atlantic/St_Helena", "Atlantic/Stanley", "Australia/Adelaide", "Australia/Brisbane", "Australia/Broken_Hill", "Australia/Darwin", "Australia/Eucla", "Australia/Hobart", "Australia/Lindeman", "Australia/Lord_Howe", "Australia/Melbourne", "Australia/Perth", "Australia/Sydney", "Etc/GMT", "Europe/Amsterdam", "Europe/Andorra", "Europe/Astrakhan", "Europe/Athens", "Europe/Belgrade", "Europe/Berlin", "Europe/Bratislava", "Europe/Brussels", "Europe/Bucharest", "Europe/Budapest", "Europe/Busingen", "Europe/Chisinau", "Europe/Copenhagen", "Europe/Dublin", "Europe/Gibraltar", "Europe/Guernsey", "Europe/Helsinki", "Europe/Isle_of_Man", "Europe/Istanbul", "Europe/Jersey", "Europe/Kaliningrad", "Europe/Kiev", "Europe/Kirov", "Europe/Lisbon", "Europe/Ljubljana", "Europe/London", "Europe/Luxembourg", "Europe/Madrid", "Europe/Malta", "Europe/Mariehamn", "Europe/Minsk", "Europe/Monaco", "Europe/Moscow", "Europe/Oslo", "Europe/Paris", "Europe/Podgorica", "Europe/Prague", "Europe/Riga", "Europe/Rome", "Europe/Samara", "Europe/San_Marino", "Europe/Sarajevo", "Europe/Saratov", "Europe/Simferopol", "Europe/Skopje", "Europe/Sofia", "Europe/Stockholm", "Europe/Tallinn", "Europe/Tirane", "Europe/Ulyanovsk", "Europe/Vaduz", "Europe/Vatican", "Europe/Vienna", "Europe/Vilnius", "Europe/Volgograd", "Europe/Warsaw", "Europe/Zagreb", "Europe/Zurich", "Indian/Antananarivo", "Indian/Chagos", "Indian/Christmas", "Indian/Cocos", "Indian/Comoro", "Indian/Kerguelen", "Indian/Mahe", "Indian/Maldives", "Indian/Mauritius", "Indian/Mayotte", "Indian/Reunion", "Pacific/Apia", "Pacific/Auckland", "Pacific/Bougainville", "Pacific/Chatham", "Pacific/Easter", "Pacific/Efate", "Pacific/Enderbury", "Pacific/Fakaofo", "Pacific/Fiji", "Pacific/Funafuti", "Pacific/Galapagos", "Pacific/Gambier", "Pacific/Guadalcanal", "Pacific/Guam", "Pacific/Honolulu", "Pacific/Kiritimati", "Pacific/Kosrae", "Pacific/Kwajalein", "Pacific/Majuro", "Pacific/Marquesas", "Pacific/Midway", "Pacific/Nauru", "Pacific/Niue", "Pacific/Norfolk", "Pacific/Noumea", "Pacific/Pago_Pago", "Pacific/Palau", "Pacific/Pitcairn", "Pacific/Ponape", "Pacific/Port_Moresby", "Pacific/Rarotonga", "Pacific/Saipan", "Pacific/Tahiti", "Pacific/Tarawa", "Pacific/Tongatapu", "Pacific/Truk", "Pacific/Wake", "Pacific/Wallis"];
var ALIASES = ["Africa/Asmara", "Africa/Asmera", "Africa/Timbuktu", "America/Argentina/Buenos_Aires", "America/Argentina/Catamarca", "America/Argentina/ComodRivadavia", "America/Argentina/Cordoba", "America/Argentina/Jujuy", "America/Argentina/Mendoza", "America/Atikokan", "America/Atka", "America/Buenos_Aires", "America/Catamarca", "America/Coral_Harbour", "America/Cordoba", "America/Ensenada", "America/Fort_Wayne", "America/Godthab", "America/Indiana/Indianapolis", "America/Indianapolis", "America/Jujuy", "America/Kentucky/Louisville", "America/Knox_IN", "America/Louisville", "America/Mendoza", "America/Montreal", "America/Nipigon", "America/Nuuk", "America/Pangnirtung", "America/Porto_Acre", "America/Rainy_River", "America/Rosario", "America/Santa_Isabel", "America/Shiprock", "America/Thunder_Bay", "America/Virgin", "America/Yellowknife", "Antarctica/South_Pole", "Asia/Ashkhabad", "Asia/Calcutta", "Asia/Choibalsan", "Asia/Chongqing", "Asia/Chungking", "Asia/Dacca", "Asia/Harbin", "Asia/Ho_Chi_Minh", "Asia/Istanbul", "Asia/Kashgar", "Asia/Kathmandu", "Asia/Katmandu", "Asia/Kolkata", "Asia/Macao", "Asia/Rangoon", "Asia/Saigon", "Asia/Tel_Aviv", "Asia/Thimbu", "Asia/Ujung_Pandang", "Asia/Ulan_Bator", "Asia/Yangon", "Atlantic/Faeroe", "Atlantic/Faroe", "Atlantic/Jan_Mayen", "Australia/ACT", "Australia/Canberra", "Australia/Currie", "Australia/LHI", "Australia/NSW", "Australia/North", "Australia/Queensland", "Australia/South", "Australia/Tasmania", "Australia/Victoria", "Australia/West", "Australia/Yancowinna", "Brazil/Acre", "Brazil/DeNoronha", "Brazil/East", "Brazil/West", "Canada/Atlantic", "Canada/Central", "Canada/East-Saskatchewan", "Canada/Eastern", "Canada/Mountain", "Canada/Newfoundland", "Canada/Pacific", "Canada/Saskatchewan", "Canada/Yukon", "Chile/Continental", "Chile/EasterIsland", "Etc/GMT+0", "Etc/GMT-0", "Etc/GMT0", "Etc/Greenwich", "Etc/UCT", "Etc/Universal", "Etc/Zulu", "Europe/Belfast", "Europe/Kiev", "Europe/Kyiv", "Europe/Nicosia", "Europe/Tiraspol", "Europe/Uzhgorod", "Europe/Zaporozhye", "Mexico/BajaNorte", "Mexico/BajaSur", "Mexico/General", "Pacific/Chuuk", "Pacific/Enderbury", "Pacific/Johnston", "Pacific/Kanton", "Pacific/Pohnpei", "Pacific/Ponape", "Pacific/Samoa", "Pacific/Truk", "Pacific/Yap", "US/Alaska", "US/Aleutian", "US/Arizona", "US/Central", "US/East-Indiana", "US/Eastern", "US/Hawaii", "US/Indiana-Starke", "US/Michigan", "US/Mountain", "US/Pacific", "US/Pacific-New", "US/Samoa", "CET", "CST6CDT", "Cuba", "EET", "EST", "EST5EDT", "Egypt", "Eire", "Factory", "GB", "GB-Eire", "GMT", "GMT+0", "GMT-0", "GMT0", "Greenwich", "HST", "Hongkong", "Iceland", "Iran", "Israel", "Jamaica", "Japan", "Kwajalein", "Libya", "MET", "MST", "MST7MDT", "NZ", "NZ-CHAT", "Navajo", "PRC", "PST8PDT", "Poland", "Portugal", "ROC", "ROK", "Singapore", "Turkey", "UCT", "UTC", "Universal", "W-SU", "WET", "Zulu"];

function out(s) { print(s); }
function tryf(f) { try { return f(); } catch (e) { return "!" + e.name; } }

CURRENCIES.forEach(function (c) {
    var row = [c];
    ["symbol", "narrowSymbol", "code", "name"].forEach(function (d) {
        [1, -2.5, 1234567.891].forEach(function (n) {
            row.push(tryf(function () { return new Intl.NumberFormat("en", {style: "currency", currency: c, currencyDisplay: d}).format(n); }));
        });
    });
    row.push(tryf(function () { return new Intl.NumberFormat("en", {style: "currency", currency: c, currencySign: "accounting"}).format(-3); }));
    out(row.join(" | "));
});

UNITS.concat(["kilometer-per-hour", "mile-per-gallon", "liter-per-kilometer", "megabyte-per-second", "meter-per-second"]).forEach(function (u) {
    var row = [u];
    ["long", "short", "narrow"].forEach(function (d) {
        [1, 2, 0.5].forEach(function (n) {
            row.push(tryf(function () { return new Intl.NumberFormat("en", {style: "unit", unit: u, unitDisplay: d}).format(n); }));
        });
    });
    out(row.join(" | "));
});

["standard", "scientific", "engineering", "compact"].forEach(function (notation) {
    ["short", "long"].forEach(function (cd) {
        out(notation + " " + cd + ": " + [0, 1.5, 999, 12345, 1e6, 2.5e9, 1e15, -0.00012].map(function (n) {
            return tryf(function () { return new Intl.NumberFormat("en", {notation: notation, compactDisplay: cd}).format(n); });
        }).join(" | "));
    });
});

["cardinal", "ordinal"].forEach(function (type) {
    var pr = new Intl.PluralRules("en", {type: type});
    var r = [];
    for (var i = 0; i < 125; i++) r.push(pr.select(i));
    out(type + ": " + r.join(",") + " " + pr.select(1.5) + " " + pr.resolvedOptions().pluralCategories.join(","));
});

["year", "quarter", "month", "week", "day", "hour", "minute", "second"].forEach(function (u) {
    ["long", "short", "narrow"].forEach(function (style) {
        ["always", "auto"].forEach(function (numeric) {
            var rtf = new Intl.RelativeTimeFormat("en", {style: style, numeric: numeric});
            out("rtf " + u + " " + style + " " + numeric + ": " + [-2, -1, -0, 0, 1, 2, 1.5].map(function (n) { return rtf.format(n, u); }).join(" | "));
        });
    });
});

var STYLES = ["long", "short", "longGeneric", "shortGeneric", "longOffset", "shortOffset"];
var years = [];
for (var y = 1900; y <= 2040; y += (y < 1970 ? 10 : 1)) years.push(y);
function zoneName(f, t) {
    var parts = f.formatToParts(t);
    for (var i = 0; i < parts.length; i++) if (parts[i].type === "timeZoneName") return parts[i].value;
    return "";
}
// January and July of each year, written only when the pair changes.
ZONES.forEach(function (z) {
    STYLES.forEach(function (style) {
        var f = tryf(function () { return new Intl.DateTimeFormat("en", {timeZone: z, timeZoneName: style}); });
        if (typeof f === "string") { out(z + " " + style + " " + f); return; }
        var last = null;
        years.forEach(function (y) {
            var v = zoneName(f, Date.UTC(y, 0, 15, 12)) + " / " + zoneName(f, Date.UTC(y, 6, 15, 12));
            if (v !== last) { out(z + " " + style + " " + y + " " + v); last = v; }
        });
    });
});
ALIASES.forEach(function (a) {
    out("alias " + a + " -> " + tryf(function () { return new Intl.DateTimeFormat("en", {timeZone: a}).resolvedOptions().timeZone; }));
});

var D1 = Date.UTC(2024, 2, 5, 14, 7, 9, 123), D0 = Date.UTC(-50, 11, 31, 1, 2, 3);
var DS = [undefined, "full", "long", "medium", "short"];
DS.forEach(function (ds) {
    DS.forEach(function (ts) {
        if (!ds && !ts) return;
        var f = new Intl.DateTimeFormat("en", {dateStyle: ds, timeStyle: ts, timeZone: "America/New_York"});
        out("style " + ds + "/" + ts + ": " + f.format(D1) + " | " + f.format(D0) + " | " + tryf(function () { return f.formatRange(D1, D1 + 86400000 * 40); }));
    });
});

var FIELDS = {
    weekday: ["long", "short", "narrow"], era: ["long", "short", "narrow"],
    year: ["numeric", "2-digit"], month: ["numeric", "2-digit", "long", "short", "narrow"],
    day: ["numeric", "2-digit"], hour: ["numeric", "2-digit"], minute: ["numeric", "2-digit"],
    second: ["numeric", "2-digit"], dayPeriod: ["narrow", "short", "long"]
};
var COMBOS = [
    ["year"], ["month"], ["day"], ["weekday"], ["hour"], ["minute"], ["second"], ["era"], ["dayPeriod"],
    ["year", "month"], ["month", "day"], ["year", "month", "day"], ["weekday", "month", "day"],
    ["weekday", "year", "month", "day"], ["era", "year", "month", "day"], ["hour", "minute"],
    ["hour", "minute", "second"], ["minute", "second"], ["month", "day", "hour", "minute"],
    ["year", "month", "day", "hour", "minute", "second"], ["weekday", "hour"], ["era", "year"],
    ["hour", "dayPeriod"], ["year", "weekday"], ["month", "weekday"], ["day", "hour"]
];
var RANGES = [
    ["year", Date.UTC(2026, 1, 3, 4, 5, 6)], ["month", Date.UTC(2024, 7, 5, 14, 7, 9)],
    ["day", Date.UTC(2024, 2, 9, 14, 7, 9)], ["ampm", Date.UTC(2024, 2, 5, 3, 7, 9)],
    ["hour", Date.UTC(2024, 2, 5, 16, 7, 9)], ["minute", Date.UTC(2024, 2, 5, 14, 40, 9)],
    ["same", D1 + 400]
];
COMBOS.forEach(function (combo) {
    function walk(i, opts, label) {
        if (i === combo.length) {
            [undefined, true, false].forEach(function (h12) {
                if (h12 !== undefined && combo.indexOf("hour") < 0) return;
                var o = {timeZone: "UTC"};
                for (var k in opts) o[k] = opts[k];
                if (h12 !== undefined) o.hour12 = h12;
                var f = tryf(function () { return new Intl.DateTimeFormat("en", o); });
                if (typeof f === "string") { out(label + " h12=" + h12 + " " + f); return; }
                out(label + " h12=" + h12 + ": " + f.format(D1) + " | " + f.format(D0) + " | " + RANGES.map(function (r) {
                    return r[0] + "=" + tryf(function () { return f.formatRange(D1, r[1]); });
                }).join(" | "));
            });
            return;
        }
        FIELDS[combo[i]].forEach(function (v) {
            var o = {}; for (var k in opts) o[k] = opts[k];
            o[combo[i]] = v;
            walk(i + 1, o, label + " " + combo[i] + "=" + v);
        });
    }
    walk(0, {}, "fields");
});
[1, 2, 3].forEach(function (n) {
    out("fsd " + n + ": " + new Intl.DateTimeFormat("en", {second: "numeric", fractionalSecondDigits: n, timeZone: "UTC"}).format(D1));
});
