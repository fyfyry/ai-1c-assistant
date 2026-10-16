// Вспомогательные классы моста ИИ-помощника 1С: обезличивание персональных данных и построение diff.
// Подключается из ai-common.ps1 через Add-Type (компилятор Windows PowerShell 5.1 — только C# 5).
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace AI1C
{
    // Заменяет персональные данные метками вида [ФИО_1] и восстанавливает их обратно.
    // Соответствие меток и значений хранится в файле и общее для моста и синхронизации хранилища:
    // изменения делаются между Begin() и End() под именованным мьютексом.
    public class Anonymizer
    {
        const string Categories = "ФИО|EMAIL|ТЕЛЕФОН|ИНН|СНИЛС|ПАСПОРТ|КАРТА|СЧЕТ|РАЗРАБОТЧИК";
        const string PatronymicEnd = @"(?:вич|вна|ична|инична|ьич)(?:а|у|ем|е|ом|ой|ы|ну|не|ной)?";

        // Три отдельных выражения работают намного быстрее одного общего: у каждого простой первый символ.
        static readonly Regex EmailPattern = new Regex(
            @"(?<![\w.+-])[\w.+-]+@[\w-]+(?:\.[\w-]+)*\.[A-Za-zА-Яа-я]{2,}\b", RegexOptions.Compiled);

        static readonly Regex NumberPattern = new Regex(
            @"(?<CARD>(?<![\w-])\d{4}[ -]?\d{4}[ -]?\d{4}[ -]?\d{4}(?![\w-]))" +
            @"|(?<ACCOUNT>(?<![\w-])(?:40817|40820|423\d\d|426\d\d)\d{15}(?![\w-]))" +
            @"|(?<SNILS>(?<![\w-])\d{3}-\d{3}-\d{3}[ -]\d{2}(?![\w-]))" +
            @"|(?<PHONE>(?<![\w+])(?:\+7|8)[ \-(]{0,2}\d{3}[ \-)]{0,2}\d{3}[ -]?\d{2}[ -]?\d{2}(?![\w-]))" +
            @"|(?<INN>(?<![\w-])\d{12}(?![\w-]))" +
            @"|(?<PASSPORT>(?<![\w-])\d{2} ?\d{2} +(?:№ ?)?\d{6}(?![\w-]))",
            RegexOptions.Compiled);

        static readonly Regex NamePattern = new Regex(
            @"\b(?:[А-ЯЁ][а-яё]+(?:-[А-ЯЁ][а-яё]+)? +[А-ЯЁ][а-яё]+ +[А-ЯЁ][а-яё]+" + PatronymicEnd + @"\b" +
            @"|[А-ЯЁ][а-яё]+ +[А-ЯЁ][а-яё]+" + PatronymicEnd + @" +[А-ЯЁ][а-яё]+(?:-[А-ЯЁ][а-яё]+)?\b" +
            @"|[А-ЯЁ][а-яё]{2,}(?:-[А-ЯЁ][а-яё]+)? +[А-ЯЁ]\. ?[А-ЯЁ]\.(?! ?[А-ЯЁ]\.)" +
            @"|(?<![А-ЯЁа-яё]\. ?)[А-ЯЁ]\. ?[А-ЯЁ]\. ?[А-ЯЁ][а-яё]{2,}(?:-[А-ЯЁ][а-яё]+)?\b)",
            RegexOptions.Compiled);
        static readonly Regex TokenPattern = new Regex(@"\[(?:" + Categories + @")_\d+\]", RegexOptions.Compiled);

        readonly string path;
        readonly Mutex mutex;
        Dictionary<string, string> tokens = new Dictionary<string, string>();   // категория + \u0001 + значение -> метка
        Dictionary<string, string> values = new Dictionary<string, string>();   // метка -> значение для подстановки
        Dictionary<string, int> counters = new Dictionary<string, int>();
        List<string> knownNames = new List<string>();
        DateTime loadedTime = DateTime.MinValue;
        bool changed;
        int depth;

        public Anonymizer(string path)
        {
            this.path = path;
            mutex = new Mutex(false, @"Local\AI1C_PII_" + ((uint)path.ToLowerInvariant().GetHashCode()).ToString("x8"));
        }

        public void Begin()
        {
            if (depth++ > 0) return;
            try { mutex.WaitOne(); } catch (AbandonedMutexException) { }
            if (File.Exists(path) && File.GetLastWriteTimeUtc(path) != loadedTime) Load();
        }

        public void End()
        {
            if (--depth > 0) return;
            try
            {
                if (changed) Save();
            }
            finally
            {
                changed = false;
                mutex.ReleaseMutex();
            }
        }

        // Полные имена пользователей базы: их заменяем точно, даже если шаблон ФИО их не распознал.
        public void SetKnownNames(IEnumerable<string> names)
        {
            var list = new List<string>();
            foreach (var n in names)
            {
                if (n == null) continue;
                var name = Regex.Replace(n, @"\s+", " ").Trim();
                if (name.Length >= 5 && name.Contains(" ") && !list.Contains(name)) list.Add(name);
            }
            list.Sort((a, b) => b.Length.CompareTo(a.Length));
            knownNames = list;
        }

        public string Protect(string text)
        {
            if (string.IsNullOrEmpty(text)) return text;
            foreach (var name in knownNames)
            {
                if (text.IndexOf(name, StringComparison.Ordinal) >= 0) text = text.Replace(name, Token("ФИО", name));
            }
            if (text.IndexOf('@') >= 0) text = EmailPattern.Replace(text, m => Token("EMAIL", m.Value.ToLowerInvariant(), m.Value));
            text = NumberPattern.Replace(text, EvaluateNumber);
            return NamePattern.Replace(text, m => Token("ФИО", m.Value, m.Value));
        }

        public string Restore(string text)
        {
            if (string.IsNullOrEmpty(text)) return text;
            return TokenPattern.Replace(text, m =>
            {
                string value;
                return values.TryGetValue(m.Value, out value) ? value : m.Value;
            });
        }

        // Метка для явно известного значения, например автора версии в хранилище.
        public string Token(string category, string value)
        {
            return Token(category, value, value);
        }

        // key — нормализованное значение (одинаковые данные в разной записи получают одну метку),
        // display — как значение подставляется обратно в ответ.
        string Token(string category, string key, string display)
        {
            key = Regex.Replace(key ?? "", @"\s+", " ").Trim();
            if (key.Length == 0) return display;
            var value = Regex.Replace(display, @"\s+", " ").Trim();
            key = category + "\u0001" + key;
            string token;
            if (tokens.TryGetValue(key, out token)) return token;
            int n;
            counters.TryGetValue(category, out n);
            n++;
            counters[category] = n;
            token = "[" + category + "_" + n + "]";
            tokens[key] = token;
            values[token] = value;
            changed = true;
            return token;
        }

        // Обезличивает текстовые файлы, изменённые после since. Время изменения файлов сохраняется.
        public int ProtectFiles(string dir, string mask, DateTime since)
        {
            if (!Directory.Exists(dir)) return 0;
            int count = 0;
            foreach (var file in Directory.EnumerateFiles(dir, mask, SearchOption.AllDirectories))
            {
                var info = new FileInfo(file);
                if (info.LastWriteTime < since) continue;
                if (ProtectFile(file)) count++;
            }
            return count;
        }

        public bool ProtectFile(string file)
        {
            var bytes = File.ReadAllBytes(file);
            bool bom = bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;
            var text = Encoding.UTF8.GetString(bytes, bom ? 3 : 0, bytes.Length - (bom ? 3 : 0));
            var result = Protect(text);
            if (result == text) return false;
            var time = File.GetLastWriteTimeUtc(file);
            File.WriteAllText(file, result, new UTF8Encoding(bom));
            File.SetLastWriteTimeUtc(file, time);
            return true;
        }

        string EvaluateNumber(Match m)
        {
            var v = m.Value;
            var digits = Digits(v);
            // Нули и другие повторы одной цифры — заглушки, а не данные.
            if (digits.Trim(digits[0]).Length == 0) return v;
            if (m.Groups["CARD"].Success) return Luhn(digits) ? Token("КАРТА", digits, v) : v;
            if (m.Groups["ACCOUNT"].Success) return Token("СЧЕТ", v, v);
            if (m.Groups["SNILS"].Success) return Token("СНИЛС", digits, v);
            if (m.Groups["PHONE"].Success) return Token("ТЕЛЕФОН", digits.Substring(digits.Length - 10), v);
            // ИНН начинается с кода региона, «00» не бывает — так начинаются коды и константы в модулях.
            if (m.Groups["INN"].Success) return !v.StartsWith("00") && InnValid(v) ? Token("ИНН", v, v) : v;
            if (m.Groups["PASSPORT"].Success) return Token("ПАСПОРТ", digits, v);
            return v;
        }

        static string Digits(string s)
        {
            var sb = new StringBuilder();
            foreach (var c in s) if (c >= '0' && c <= '9') sb.Append(c);
            return sb.ToString();
        }

        static bool Luhn(string digits)
        {
            int sum = 0;
            for (int i = 0; i < digits.Length; i++)
            {
                int d = digits[digits.Length - 1 - i] - '0';
                if (i % 2 == 1) { d *= 2; if (d > 9) d -= 9; }
                sum += d;
            }
            return sum % 10 == 0;
        }

        // Контрольные числа ИНН физического лица (12 цифр).
        static bool InnValid(string inn)
        {
            int[] w1 = { 7, 2, 4, 10, 3, 5, 9, 4, 6, 8 };
            int[] w2 = { 3, 7, 2, 4, 10, 3, 5, 9, 4, 6, 8 };
            int s1 = 0, s2 = 0;
            for (int i = 0; i < 10; i++) s1 += w1[i] * (inn[i] - '0');
            for (int i = 0; i < 11; i++) s2 += w2[i] * (inn[i] - '0');
            return (s1 % 11 % 10) == inn[10] - '0' && (s2 % 11 % 10) == inn[11] - '0';
        }

        // Формат файла: метка, категория, нормализованное значение, значение для подстановки — через табуляцию.
        void Load()
        {
            tokens.Clear();
            values.Clear();
            counters.Clear();
            foreach (var line in File.ReadAllLines(path, Encoding.UTF8))
            {
                var parts = line.Split('\t');
                if (parts.Length != 4) continue;
                tokens[parts[1] + "\u0001" + Unescape(parts[2])] = parts[0];
                values[parts[0]] = Unescape(parts[3]);
                int n;
                if (!int.TryParse(parts[0].Substring(parts[1].Length + 2).TrimEnd(']'), out n)) continue;
                int current;
                counters.TryGetValue(parts[1], out current);
                if (n > current) counters[parts[1]] = n;
            }
            loadedTime = File.GetLastWriteTimeUtc(path);
        }

        void Save()
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            var sb = new StringBuilder();
            foreach (var pair in tokens)
            {
                var sep = pair.Key.IndexOf('\u0001');
                sb.Append(pair.Value).Append('\t').Append(pair.Key.Substring(0, sep)).Append('\t')
                  .Append(Escape(pair.Key.Substring(sep + 1))).Append('\t').Append(Escape(values[pair.Value])).Append('\n');
            }
            File.WriteAllText(path, sb.ToString(), new UTF8Encoding(false));
            loadedTime = File.GetLastWriteTimeUtc(path);
        }

        static string Escape(string s) { return s.Replace("\\", "\\\\").Replace("\n", "\\n").Replace("\t", "\\t"); }

        static string Unescape(string s)
        {
            var sb = new StringBuilder();
            for (int i = 0; i < s.Length; i++)
            {
                if (s[i] == '\\' && i + 1 < s.Length)
                {
                    i++;
                    sb.Append(s[i] == 'n' ? '\n' : s[i] == 't' ? '\t' : s[i]);
                }
                else sb.Append(s[i]);
            }
            return sb.ToString();
        }
    }
    // Построчное сравнение (алгоритм Майерса) с выводом в формате unified diff.
    public static class Differ
    {
        const int MaxEditDistance = 4000;

        public static string Unified(string before, string after, string labelBefore, string labelAfter)
        {
            var a = SplitLines(before);
            var b = SplitLines(after);
            var ops = Compare(a, b);

            var sb = new StringBuilder();
            const int context = 3;
            int i = 0;
            while (i < ops.Count)
            {
                if (ops[i].Kind == ' ') { i++; continue; }
                int start = Math.Max(0, i - context);
                int end = i;
                // Расширяем блок, пока изменения ближе 2*context строк друг к другу.
                int j = i;
                while (j < ops.Count)
                {
                    if (ops[j].Kind != ' ') { end = j; j++; continue; }
                    int k = j;
                    while (k < ops.Count && ops[k].Kind == ' ') k++;
                    if (k < ops.Count && k - j <= 2 * context) { j = k; continue; }
                    break;
                }
                int stop = Math.Min(ops.Count - 1, end + context);
                if (sb.Length == 0) sb.Append("--- ").Append(labelBefore).Append("\n+++ ").Append(labelAfter).Append('\n');

                int aStart = -1, bStart = -1, aLen = 0, bLen = 0;
                for (int x = start; x <= stop; x++)
                {
                    var op = ops[x];
                    if (op.Kind != '+') { if (aStart < 0) aStart = op.A; aLen++; }
                    if (op.Kind != '-') { if (bStart < 0) bStart = op.B; bLen++; }
                }
                if (aStart < 0) aStart = NextA(ops, start);
                if (bStart < 0) bStart = NextB(ops, start);
                sb.Append("@@ -").Append(aLen == 0 ? aStart : aStart + 1).Append(',').Append(aLen)
                  .Append(" +").Append(bLen == 0 ? bStart : bStart + 1).Append(',').Append(bLen).Append(" @@\n");
                for (int x = start; x <= stop; x++)
                {
                    var op = ops[x];
                    sb.Append(op.Kind).Append(op.Kind == '+' ? b[op.B] : a[op.A]).Append('\n');
                }
                i = stop + 1;
            }
            return sb.ToString();
        }

        static int NextA(List<Op> ops, int from)
        {
            for (int x = from; x < ops.Count; x++) if (ops[x].Kind != '+') return ops[x].A;
            int last = 0;
            foreach (var op in ops) if (op.Kind != '+') last = op.A + 1;
            return last;
        }

        static int NextB(List<Op> ops, int from)
        {
            for (int x = from; x < ops.Count; x++) if (ops[x].Kind != '-') return ops[x].B;
            int last = 0;
            foreach (var op in ops) if (op.Kind != '-') last = op.B + 1;
            return last;
        }

        internal static string[] SplitLines(string text)
        {
            if (string.IsNullOrEmpty(text)) return new string[0];
            text = text.Replace("\r\n", "\n");
            if (text.EndsWith("\n")) text = text.Substring(0, text.Length - 1);
            return text.Split('\n');
        }

        internal struct Op
        {
            public char Kind; public int A; public int B;
            public Op(char kind, int a, int b) { Kind = kind; A = a; B = b; }
        }

        internal static List<Op> Compare(string[] a, string[] b)
        {
            // Строки заменяем числами — так сравнение быстрее.
            var ids = new Dictionary<string, int>();
            var x = new int[a.Length];
            var y = new int[b.Length];
            for (int i = 0; i < a.Length; i++) x[i] = Id(ids, a[i]);
            for (int i = 0; i < b.Length; i++) y[i] = Id(ids, b[i]);

            int pre = 0;
            while (pre < x.Length && pre < y.Length && x[pre] == y[pre]) pre++;
            int suf = 0;
            while (suf < x.Length - pre && suf < y.Length - pre && x[x.Length - 1 - suf] == y[y.Length - 1 - suf]) suf++;

            var ops = new List<Op>();
            for (int i = 0; i < pre; i++) ops.Add(new Op(' ', i, i));
            var middle = Myers(x, pre, x.Length - suf, y, pre, y.Length - suf);
            if (middle == null)
            {
                middle = new List<Op>();
                for (int i = pre; i < x.Length - suf; i++) middle.Add(new Op('-', i, 0));
                for (int i = pre; i < y.Length - suf; i++) middle.Add(new Op('+', 0, i));
            }
            ops.AddRange(middle);
            for (int i = 0; i < suf; i++) ops.Add(new Op(' ', x.Length - suf + i, y.Length - suf + i));
            return ops;
        }

        static int Id(Dictionary<string, int> ids, string s)
        {
            int id;
            if (!ids.TryGetValue(s, out id)) { id = ids.Count; ids[s] = id; }
            return id;
        }

        // Возвращает null, если отличий слишком много — тогда участок считается заменённым целиком.
        static List<Op> Myers(int[] x, int x0, int x1, int[] y, int y0, int y1)
        {
            int n = x1 - x0, m = y1 - y0;
            int max = Math.Min(n + m, MaxEditDistance);
            int offset = max + 1;
            var v = new int[2 * max + 3];
            var trace = new List<int[]>();
            int found = -1;
            for (int d = 0; d <= max; d++)
            {
                var snapshot = new int[2 * d + 3];
                for (int k = -d - 1; k <= d + 1; k++) snapshot[k + d + 1] = v[k + offset];
                trace.Add(snapshot);
                for (int k = -d; k <= d; k += 2)
                {
                    int xx = (k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset])) ? v[k + 1 + offset] : v[k - 1 + offset] + 1;
                    int yy = xx - k;
                    while (xx < n && yy < m && x[x0 + xx] == y[y0 + yy]) { xx++; yy++; }
                    v[k + offset] = xx;
                    if (xx >= n && yy >= m) { found = d; break; }
                }
                if (found >= 0) break;
            }
            if (found < 0) return null;

            var result = new List<Op>();
            int cx = n, cy = m;
            for (int d = found; d > 0; d--)
            {
                var vd = trace[d];
                int k = cx - cy;
                bool down = k == -d || (k != d && vd[k - 1 + d + 1] < vd[k + 1 + d + 1]);
                int prevK = down ? k + 1 : k - 1;
                int prevX = vd[prevK + d + 1];
                int prevY = prevX - prevK;
                while (cx > prevX && cy > prevY) { cx--; cy--; result.Add(new Op(' ', x0 + cx, y0 + cy)); }
                if (down) { cy--; result.Add(new Op('+', 0, y0 + cy)); }
                else { cx--; result.Add(new Op('-', x0 + cx, 0)); }
            }
            while (cx > 0 && cy > 0) { cx--; cy--; result.Add(new Op(' ', x0 + cx, y0 + cy)); }
            result.Reverse();
            return result;
        }
    }

    // HTTP-запрос к API в фоновой задаче: мост тем временем продолжает отмечать, что жив.
    public static class Http
    {
        public static System.Threading.Tasks.Task<string> PostJsonAsync(string url, string apiKey, string json, int timeoutMs)
        {
            return System.Threading.Tasks.Task.Run(() => PostJson(url, apiKey, json, timeoutMs));
        }

        public static string Get(string url, string apiKey, int timeoutMs)
        {
            System.Net.ServicePointManager.SecurityProtocol |= System.Net.SecurityProtocolType.Tls12;
            var request = (System.Net.HttpWebRequest)System.Net.WebRequest.Create(url);
            request.Method = "GET";
            request.Accept = "application/json";
            request.Headers["Authorization"] = "Bearer " + apiKey;
            request.Timeout = timeoutMs;
            try
            {
                using (var response = (System.Net.HttpWebResponse)request.GetResponse())
                using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
                    return reader.ReadToEnd();
            }
            catch (System.Net.WebException e)
            {
                var response = e.Response as System.Net.HttpWebResponse;
                if (response == null) throw;
                using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
                    throw new Exception("HTTP " + (int)response.StatusCode + ": " + reader.ReadToEnd());
            }
        }

        public static string PostJson(string url, string apiKey, string json, int timeoutMs)
        {
            System.Net.ServicePointManager.SecurityProtocol |= System.Net.SecurityProtocolType.Tls12;
            var request = (System.Net.HttpWebRequest)System.Net.WebRequest.Create(url);
            request.Method = "POST";
            request.ContentType = "application/json; charset=utf-8";
            request.Accept = "application/json";
            request.Headers["Authorization"] = "Bearer " + apiKey;
            request.Timeout = timeoutMs;
            request.ReadWriteTimeout = timeoutMs;
            var body = Encoding.UTF8.GetBytes(json);
            request.ContentLength = body.Length;
            using (var stream = request.GetRequestStream()) stream.Write(body, 0, body.Length);
            try
            {
                using (var response = (System.Net.HttpWebResponse)request.GetResponse())
                using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
                    return reader.ReadToEnd();
            }
            catch (System.Net.WebException e)
            {
                var response = e.Response as System.Net.HttpWebResponse;
                if (response == null) throw;
                using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
                    throw new Exception("HTTP " + (int)response.StatusCode + ": " + reader.ReadToEnd());
            }
        }
    }

    // Инструменты модели для работы с рабочей папкой базы: поиск, список файлов, чтение.
    // Все пути — относительно корня рабочей папки, выйти за её пределы нельзя.
    public class WorkspaceTools
    {
        readonly string root;
        List<string> allFiles;

        public WorkspaceTools(string root)
        {
            this.root = Path.GetFullPath(root).TrimEnd('\\');
        }

        string Resolve(string relative)
        {
            relative = (relative ?? "").Replace('/', '\\').TrimStart('\\');
            var full = Path.GetFullPath(Path.Combine(root, relative)).TrimEnd('\\');
            if (!full.Equals(root, StringComparison.OrdinalIgnoreCase) &&
                !full.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase))
                throw new Exception("Путь вне рабочей папки: " + relative);
            return full;
        }

        string Relative(string full)
        {
            return full.Length <= root.Length ? "" : full.Substring(root.Length + 1).Replace('\\', '/');
        }

        List<string> Files()
        {
            if (allFiles == null)
            {
                allFiles = new List<string>();
                foreach (var f in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)) allFiles.Add(f);
            }
            return allFiles;
        }

        static Regex GlobToRegex(string glob)
        {
            glob = glob.Replace('\\', '/').TrimStart('/');
            var sb = new StringBuilder("^");
            for (int i = 0; i < glob.Length; i++)
            {
                char c = glob[i];
                if (c == '*' && i + 1 < glob.Length && glob[i + 1] == '*')
                {
                    if (i + 2 < glob.Length && glob[i + 2] == '/') { sb.Append("(?:.*/)?"); i += 2; }
                    else { sb.Append(".*"); i++; }
                }
                else if (c == '*') sb.Append("[^/]*");
                else if (c == '?') sb.Append("[^/]");
                else sb.Append(Regex.Escape(c.ToString()));
            }
            sb.Append("$");
            return new Regex(sb.ToString(), RegexOptions.IgnoreCase);
        }

        // Шаблон без «/» проверяется по имени файла, с «/» — по пути от корня.
        static bool GlobMatch(Regex rx, string glob, string relative)
        {
            return glob.IndexOf('/') < 0 && glob.IndexOf('\\') < 0 ? rx.IsMatch(Path.GetFileName(relative)) : rx.IsMatch(relative);
        }

        public string Glob(string pattern, int max)
        {
            if (string.IsNullOrEmpty(pattern)) return "Не указан шаблон.";
            var rx = GlobToRegex(pattern);
            var sb = new StringBuilder();
            int found = 0;
            foreach (var f in Files())
            {
                var rel = Relative(f);
                if (!GlobMatch(rx, pattern, rel)) continue;
                found++;
                if (found <= max) sb.Append(rel).Append('\n');
            }
            if (found == 0) return "Файлов не найдено.";
            if (found > max) sb.Append("... и ещё ").Append(found - max).Append(" (уточните шаблон)\n");
            return sb.ToString();
        }

        public string Grep(string pattern, string path, string glob, bool ignoreCase, int max)
        {
            if (string.IsNullOrEmpty(pattern)) return "Не указан шаблон поиска.";
            Regex rx;
            try { rx = new Regex(pattern, (ignoreCase ? RegexOptions.IgnoreCase : RegexOptions.None) | RegexOptions.Multiline); }
            catch (ArgumentException e) { return "Ошибка в регулярном выражении: " + e.Message; }
            var start = Resolve(path);
            Regex globRx = string.IsNullOrEmpty(glob) ? null : GlobToRegex(glob);
            var sb = new StringBuilder();
            int matches = 0, files = 0;
            IEnumerable<string> candidates = File.Exists(start) ? new[] { start } : (IEnumerable<string>)Files();
            foreach (var f in candidates)
            {
                if (!f.StartsWith(start, StringComparison.OrdinalIgnoreCase)) continue;
                var rel = Relative(f);
                if (globRx != null && !GlobMatch(globRx, glob, rel)) continue;
                var ext = Path.GetExtension(f).ToLowerInvariant();
                if (ext == ".bin" || ext == ".png" || ext == ".gif" || ext == ".jpg" || ext == ".ico" || ext == ".zip") continue;
                if (new FileInfo(f).Length > 20 * 1024 * 1024) continue;
                string text;
                try { text = File.ReadAllText(f, Encoding.UTF8); } catch { continue; }
                if (!rx.IsMatch(text)) continue;
                files++;
                var lines = text.Split('\n');
                for (int i = 0; i < lines.Length; i++)
                {
                    if (!rx.IsMatch(lines[i])) continue;
                    matches++;
                    if (matches <= max)
                    {
                        var line = lines[i].TrimEnd('\r').Trim();
                        if (line.Length > 300) line = line.Substring(0, 300) + "…";
                        sb.Append(rel).Append(':').Append(i + 1).Append(": ").Append(line).Append('\n');
                    }
                }
            }
            if (matches == 0) return "Совпадений не найдено.";
            if (matches > max) sb.Append("... всего совпадений: ").Append(matches).Append(" в файлах: ").Append(files).Append(" (показаны первые ").Append(max).Append(", уточните поиск)\n");
            return sb.ToString();
        }

        public string Read(string path, int offset, int limit, int maxChars)
        {
            var full = Resolve(path);
            if (!File.Exists(full)) return "Файл не найден: " + path;
            var lines = File.ReadAllLines(full, Encoding.UTF8);
            if (offset < 1) offset = 1;
            if (limit < 1) limit = 400;
            var sb = new StringBuilder();
            int last = Math.Min(lines.Length, offset - 1 + limit);
            for (int i = offset - 1; i < last; i++)
            {
                var line = (i + 1).ToString() + "\t" + lines[i] + "\n";
                if (sb.Length + line.Length > maxChars)
                {
                    sb.Append("... вывод обрезан на строке ").Append(i + 1).Append(", читайте дальше с offset=").Append(i + 1).Append('\n');
                    return sb.ToString();
                }
                sb.Append(line);
            }
            if (last < lines.Length) sb.Append("... в файле строк: ").Append(lines.Length).Append(", читайте дальше с offset=").Append(last + 1).Append('\n');
            return sb.Length == 0 ? "Файл пуст или offset за концом файла (строк: " + lines.Length + ")." : sb.ToString();
        }

        // Вызов инструмента в фоновой задаче: поиск по большой выгрузке занимает секунды,
        // а мост тем временем продолжает отмечать, что жив.
        public System.Threading.Tasks.Task<string> RunAsync(string name, string pattern, string path, string glob,
            bool ignoreCase, int maxResults, int offset, int limit, int maxChars, string content)
        {
            return System.Threading.Tasks.Task.Run(() =>
            {
                switch (name)
                {
                    case "glob": return Glob(pattern, 200);
                    case "grep": return Grep(pattern, path, glob, ignoreCase, maxResults <= 0 ? 50 : Math.Min(200, maxResults));
                    case "read_file": return Read(path, offset, limit, maxChars);
                    case "list_dir": return List(path);
                    case "write_file": return Write(path, content);
                    default: return "Неизвестный инструмент: " + name;
                }
            });
        }

        // Запись разрешена только в папку output: там помощник создаёт исходники обработок, отчётов и расширений.
        public string Write(string path, string content)
        {
            var full = Resolve(path);
            var output = root + "\\output";
            if (!full.StartsWith(output + "\\", StringComparison.OrdinalIgnoreCase))
                return "Запись запрещена: писать можно только в папку output/<Имя>/.";
            Directory.CreateDirectory(Path.GetDirectoryName(full));
            var ext = Path.GetExtension(full).ToLowerInvariant();
            File.WriteAllText(full, content ?? "", new UTF8Encoding(ext == ".bsl" || ext == ".xml"));
            allFiles = null;
            return "Записано: " + Relative(full) + " (" + (content ?? "").Length + " символов)";
        }

        public string List(string path)
        {
            var full = Resolve(path);
            if (!Directory.Exists(full)) return "Папка не найдена: " + path;
            var sb = new StringBuilder();
            int n = 0;
            foreach (var d in Directory.EnumerateDirectories(full)) { if (n++ < 500) sb.Append(Relative(d)).Append("/\n"); }
            foreach (var f in Directory.EnumerateFiles(full)) { if (n++ < 500) sb.Append(Relative(f)).Append('\n'); }
            if (n > 500) sb.Append("... всего элементов: ").Append(n).Append('\n');
            return n == 0 ? "Папка пуста." : sb.ToString();
        }
    }

    // Отчёт об изменениях для программиста: код модулей — целыми процедурами и функциями с подсветкой
    // изменённых строк и фрагментов, XML — описанием по-русски (реквизиты, элементы формы, запросы СКД),
    // сырой XML — свёрнутым. Каждый блок сворачивается щелчком по заголовку.
    public static class ChangeReport
    {
        const int CollapseUnchanged = 12;   // столько неизменённых строк подряд показываем, остальное сворачиваем
        const int MaxFileChars = 3000000;

        public static string PageStart(string title)
        {
            return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"X-UA-Compatible\" content=\"IE=edge\"><style>" +
                "body{font-family:Arial,sans-serif;font-size:10pt;margin:0;padding:8px 12px;color:#000}" +
                "h3{font-size:11pt;margin:8px 0 4px}" +
                ".tools{margin:4px 0 8px}.tools a{color:#1f4e8c;margin-right:14px;cursor:pointer;text-decoration:none}" +
                ".ev{white-space:pre-wrap;margin:2px 0 6px}" +
                ".file{border:1px solid #d0d7de;margin:8px 0}" +
                ".fh{background:#f6f8fa;padding:4px 8px;cursor:pointer;font-weight:bold;border-bottom:1px solid #d0d7de}" +
                ".mh{background:#f0f3f6;padding:3px 8px;cursor:pointer;border-top:1px solid #e1e4e8;font-family:Consolas,monospace;font-size:9pt}" +
                ".st{font-weight:normal;color:#57606a;margin-left:6px;font-family:Arial,sans-serif}" +
                ".code{font-family:Consolas,monospace;font-size:9pt}" +
                ".ln{white-space:pre;display:block}" +
                ".no{display:inline-block;width:44px;color:#8c959f;text-align:right;padding-right:8px;user-select:none}" +
                ".add{background:#e6ffec}.add .chg{background:#abf2bc}" +
                ".del{background:#ffebe9}.del .chg{background:#ff818266}" +
                ".gap{color:#57606a;background:#f6f8fa;cursor:pointer;padding:1px 8px;font-family:Arial,sans-serif;font-size:9pt}" +
                ".list{margin:4px 0 4px 8px;padding-left:16px}.list li{margin:1px 0}" +
                ".raw{margin:4px 8px}.raw .ln{font-size:8.5pt}" +
                ".note{color:#57606a;padding:4px 8px}" +
                ".hid{display:none}" +
                "</style><script>" +
                "function t(h){var b=h.nextElementSibling;if(!b)return;var hid=b.className.indexOf('hid')<0;b.className=hid?b.className+' hid':b.className.replace(/ ?hid/g,'');var a=h.querySelector('.ar');if(a)a.innerHTML=hid?'\u25B8':'\u25BE';}" +
                "function showAll(o){var e=document.querySelectorAll('.fb,.mb,.rb');for(var i=0;i<e.length;i++){var c=e[i].className.replace(/ ?hid/g,'');e[i].className=o?c:c+' hid';}var a=document.querySelectorAll('.ar');for(var j=0;j<a.length;j++){a[j].innerHTML=o?'\u25BE':'\u25B8';}}" +
                "function g(x){x.style.display='none';var n=x.nextElementSibling;if(n)n.className=n.className.replace(/ ?hid/g,'');}" +"</script></head><body><h3>" + H(title) + "</h3>";
        }

        public static string Tools()
        {
            return "<div class=\"tools\"><a onclick=\"showAll(true)\">Развернуть всё</a><a onclick=\"showAll(false)\">Свернуть всё</a></div>";
        }

        public static string PageEnd() { return "</body></html>"; }

        public static string H(string s)
        {
            if (s == null) return "";
            return s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;");
        }

        static string Read(string path)
        {
            if (string.IsNullOrEmpty(path) || !File.Exists(path)) return null;
            if (new FileInfo(path).Length > MaxFileChars) return null;
            return File.ReadAllText(path, Encoding.UTF8);
        }

        static string Header(string cls, string text, string status)
        {
            return "<div class=\"" + cls + "\" data-m=\"1\" onclick=\"t(this)\">▾ " + H(text) +
                (string.IsNullOrEmpty(status) ? "" : "<span class=\"st\">" + H(status) + "</span>") + "</div>";
        }

        // Раздел одного изменённого файла. caption — понятное название («Документ «…»: модуль объекта»).
        public static string FileSection(string caption, string rel, string status, string beforePath, string afterPath)
        {
            var before = Read(beforePath);
            var after = Read(afterPath);
            var ext = Path.GetExtension(rel).ToLowerInvariant();
            var sb = new StringBuilder();
            sb.Append("<div class=\"file\">").Append(Header("fh", caption, status)).Append("<div class=\"fb\">");
            if (ext == ".bsl")
            {
                sb.Append(CodeBody(before ?? "", after ?? ""));
            }
            else if (ext == ".xml")
            {
                sb.Append(XmlBody(before, after));
                var raw = Differ.Unified(before ?? "", after ?? "", "было", "стало");
                if (raw.Length > 0)
                {
                    sb.Append("<div class=\"mh\" data-m=\"1\" onclick=\"t(this)\">▸ Показать XML<span class=\"st\">исходный текст изменений</span></div>");
                    sb.Append("<div class=\"rb raw code hid\">").Append(RawDiff(raw)).Append("</div>");
                }
            }
            else
            {
                sb.Append("<div class=\"note\">Двоичный файл (картинка, макет и т.п.) ").Append(H(status)).Append(".</div>");
            }
            sb.Append("</div></div>");
            return sb.ToString();
        }

        static string RawDiff(string unified)
        {
            var sb = new StringBuilder();
            int shown = 0;
            foreach (var line in unified.Split('\n'))
            {
                if (line.StartsWith("---") || line.StartsWith("+++")) continue;
                if (++shown > 2000) { sb.Append("<span class=\"ln note\">… обрезано</span>"); break; }
                var cls = line.StartsWith("+") ? "ln add" : line.StartsWith("-") ? "ln del" : line.StartsWith("@@") ? "ln gap" : "ln";
                sb.Append("<span class=\"").Append(cls).Append("\">").Append(H(line.Length == 0 ? " " : line)).Append("</span>");
            }
            return sb.ToString();
        }

        // ---------- Код ----------

        struct Method { public string Kind; public string Name; public int Start; public int End; }

        static readonly Regex MethodStart = new Regex(@"^\s*(?:Асинх\s+|Async\s+)?(Процедура|Функция|Procedure|Function)\s+([\wА-Яа-яЁё]+)\s*\(", RegexOptions.IgnoreCase);
        static readonly Regex MethodEnd = new Regex(@"^\s*(КонецПроцедуры|КонецФункции|EndProcedure|EndFunction)\b", RegexOptions.IgnoreCase);

        static List<Method> FindMethods(string[] lines)
        {
            var list = new List<Method>();
            for (int i = 0; i < lines.Length; i++)
            {
                var m = MethodStart.Match(lines[i]);
                if (!m.Success) continue;
                int start = i;
                // Директивы и аннотации над процедурой (&НаСервере, &После(...)) — часть процедуры.
                while (start > 0 && lines[start - 1].TrimStart().StartsWith("&")) start--;
                int end = i;
                while (end < lines.Length - 1 && !MethodEnd.IsMatch(lines[end])) end++;
                var kind = m.Groups[1].Value.ToLowerInvariant();
                list.Add(new Method { Kind = (kind == "функция" || kind == "function") ? "Функция" : "Процедура", Name = m.Groups[2].Value, Start = start, End = end });
                i = end;
            }
            return list;
        }

        static int MethodAt(List<Method> methods, int line)
        {
            for (int i = 0; i < methods.Count; i++) if (line >= methods[i].Start && line <= methods[i].End) return i;
            return -1;
        }

        static string CodeBody(string before, string after)
        {
            var a = Differ.SplitLines(before);
            var b = Differ.SplitLines(after);
            var ops = Differ.Compare(a, b);
            var ma = FindMethods(a);
            var mb = FindMethods(b);

            // Какие процедуры затронуты: ключ — имя, значение — номер в старом и новом модуле.
            var touched = new List<string>();
            var keyA = new Dictionary<string, int>();
            var keyB = new Dictionary<string, int>();
            for (int i = 0; i < ma.Count; i++) keyA[ma[i].Name.ToLowerInvariant()] = i;
            for (int i = 0; i < mb.Count; i++) keyB[mb[i].Name.ToLowerInvariant()] = i;
            bool outside = false;
            foreach (var op in ops)
            {
                if (op.Kind == ' ') continue;
                int idx = op.Kind == '+' ? MethodAt(mb, op.B) : MethodAt(ma, op.A);
                string key = idx < 0 ? null : (op.Kind == '+' ? mb[idx].Name : ma[idx].Name).ToLowerInvariant();
                if (key == null) { outside = true; continue; }
                if (!touched.Contains(key)) touched.Add(key);
            }

            var sb = new StringBuilder();
            if (touched.Count == 0 && !outside) return "<div class=\"note\">Изменений в тексте модуля нет.</div>";

            // Порядок — как в новом модуле, удалённые процедуры — в конце.
            touched.Sort((x, y) =>
            {
                int px = keyB.ContainsKey(x) ? mb[keyB[x]].Start : int.MaxValue;
                int py = keyB.ContainsKey(y) ? mb[keyB[y]].Start : int.MaxValue;
                return px.CompareTo(py);
            });
            foreach (var key in touched)
            {
                bool inA = keyA.ContainsKey(key), inB = keyB.ContainsKey(key);
                var m = inB ? mb[keyB[key]] : ma[keyA[key]];
                int aStart = inA ? ma[keyA[key]].Start : -1, aEnd = inA ? ma[keyA[key]].End : -2;
                int bStart = inB ? mb[keyB[key]].Start : -1, bEnd = inB ? mb[keyB[key]].End : -2;
                var view = new List<Differ.Op>();
                int added = 0, deleted = 0;
                foreach (var op in ops)
                {
                    bool take = op.Kind == '-' ? (op.A >= aStart && op.A <= aEnd)
                              : op.Kind == '+' ? (op.B >= bStart && op.B <= bEnd)
                              : (op.B >= bStart && op.B <= bEnd) || (!inB && op.A >= aStart && op.A <= aEnd);
                    if (!take) continue;
                    view.Add(op);
                    if (op.Kind == '+') added++; else if (op.Kind == '-') deleted++;
                }
                string status = !inA ? "добавлена" : !inB ? "удалена" : "изменена";
                if (m.Kind == "Процедура") status = !inA ? "добавлена" : !inB ? "удалена" : "изменена";
                sb.Append(Header("mh", m.Kind + " " + m.Name, status + " (+" + added + " −" + deleted + ")"));
                sb.Append("<div class=\"mb code\">").Append(RenderOps(view, a, b, true)).Append("</div>");
            }
            if (outside)
            {
                // Изменения вне процедур (переменные модуля, области, инструкции) — фрагментами,
                // по три строки до и после изменения.
                var marks = new bool[ops.Count];
                for (int i = 0; i < ops.Count; i++)
                {
                    var op = ops[i];
                    if (op.Kind == ' ') continue;
                    int idx = op.Kind == '-' ? MethodAt(ma, op.A) : MethodAt(mb, op.B);
                    if (idx >= 0) continue;
                    for (int k = Math.Max(0, i - 3); k <= Math.Min(ops.Count - 1, i + 3); k++) marks[k] = true;
                }
                var body = new StringBuilder();
                var view = new List<Differ.Op>();
                for (int i = 0; i <= ops.Count; i++)
                {
                    if (i < ops.Count && marks[i]) { view.Add(ops[i]); continue; }
                    if (view.Count == 0) continue;
                    if (body.Length > 0) body.Append("<div class=\"gap\">\u22EF</div>");
                    body.Append(RenderOps(view, a, b, false));
                    view = new List<Differ.Op>();
                }
                sb.Append(Header("mh", "Вне процедур и функций", "объявления, области, общий код"));
                sb.Append("<div class=\"mb code\">").Append(body.ToString()).Append("</div>");
            }
            return sb.ToString();
        }

        // Строки с номерами; длинные неизменённые участки сворачиваются; в парах «удалено/добавлено»
        // подсвечивается изменённая часть строки.
        static string RenderOps(List<Differ.Op> view, string[] a, string[] b, bool collapse)
        {
            var sb = new StringBuilder();
            int i = 0;
            while (i < view.Count)
            {
                if (view[i].Kind == ' ')
                {
                    int j = i;
                    while (j < view.Count && view[j].Kind == ' ') j++;
                    int run = j - i;
                    if (collapse && run > CollapseUnchanged)
                    {
                        int head = (i == 0) ? 2 : 3, tail = (j == view.Count) ? 2 : 3;
                        for (int k = i; k < i + head; k++) sb.Append(Line(view[k], a, b, null));
                        sb.Append("<div class=\"gap\" onclick=\"g(this)\">⋯ " + (run - head - tail) + " строк без изменений — показать</div><div class=\"hid\">");
                        for (int k = i + head; k < j - tail; k++) sb.Append(Line(view[k], a, b, null));
                        sb.Append("</div>");
                        for (int k = j - tail; k < j; k++) sb.Append(Line(view[k], a, b, null));
                    }
                    else
                    {
                        for (int k = i; k < j; k++) sb.Append(Line(view[k], a, b, null));
                    }
                    i = j;
                    continue;
                }
                // Блок изменений: сначала удалённые строки, потом добавленные.
                var dels = new List<Differ.Op>();
                var adds = new List<Differ.Op>();
                while (i < view.Count && view[i].Kind != ' ')
                {
                    if (view[i].Kind == '-') dels.Add(view[i]); else adds.Add(view[i]);
                    i++;
                }
                int pairs = Math.Min(dels.Count, adds.Count);
                for (int k = 0; k < dels.Count; k++)
                    sb.Append(Line(dels[k], a, b, k < pairs ? b[adds[k].B] : null));
                for (int k = 0; k < adds.Count; k++)
                    sb.Append(Line(adds[k], a, b, k < pairs ? a[dels[k].A] : null));
            }
            return sb.ToString();
        }

        static string Line(Differ.Op op, string[] a, string[] b, string pair)
        {
            string text = op.Kind == '+' ? b[op.B] : a[op.A];
            int no = op.Kind == '-' ? op.A + 1 : op.B + 1;
            string cls = op.Kind == '+' ? "ln add" : op.Kind == '-' ? "ln del" : "ln";
            string sign = op.Kind == '+' ? "+" : op.Kind == '-' ? "−" : " ";
            string body;
            if (pair != null)
            {
                // Общее начало и конец строки не выделяем — подсвечиваем только изменённую середину.
                int p = 0;
                while (p < text.Length && p < pair.Length && text[p] == pair[p]) p++;
                int s = 0;
                while (s < text.Length - p && s < pair.Length - p && text[text.Length - 1 - s] == pair[pair.Length - 1 - s]) s++;
                body = H(text.Substring(0, p)) + "<span class=\"chg\">" + H(text.Substring(p, text.Length - p - s)) + "</span>" + H(text.Substring(text.Length - s));
            }
            else body = H(text);
            return "<span class=\"" + cls + "\"><span class=\"no\">" + no + "</span>" + sign + " " + (body.Length == 0 ? " " : body) + "</span>";
        }

        // ---------- XML ----------

        static readonly Dictionary<string, string> ChildTitles = new Dictionary<string, string>
        {
            { "Attribute", "реквизит" }, { "TabularSection", "табличная часть" }, { "Form", "форма" }, { "Template", "макет" },
            { "Command", "команда" }, { "Dimension", "измерение" }, { "Resource", "ресурс" }, { "EnumValue", "значение перечисления" },
            { "AccountingFlag", "признак учета" }, { "ExtDimensionAccountingFlag", "признак учета субконто" }, { "Column", "графа" },
            { "AddressingAttribute", "реквизит адресации" }, { "URLTemplate", "шаблон URL" }, { "Operation", "операция" },
            { "Method", "метод" }, { "Recalculation", "перерасчет" }, { "Language", "язык" }, { "Subsystem", "подсистема" },
            { "CommonModule", "общий модуль" }, { "Catalog", "справочник" }, { "Document", "документ" }, { "Report", "отчет" },
            { "DataProcessor", "обработка" }, { "InformationRegister", "регистр сведений" }, { "CommonForm", "общая форма" },
            { "Role", "роль" }, { "Constant", "константа" }, { "Enum", "перечисление" }, { "AccumulationRegister", "регистр накопления" }
        };

        static readonly Dictionary<string, string> ItemTitles = new Dictionary<string, string>
        {
            { "Button", "кнопка" }, { "InputField", "поле ввода" }, { "UsualGroup", "группа" }, { "Table", "таблица" },
            { "LabelField", "поле надписи" }, { "LabelDecoration", "надпись" }, { "PictureDecoration", "картинка" },
            { "CheckBoxField", "флажок" }, { "RadioButtonField", "переключатель" }, { "Pages", "страницы" }, { "Page", "страница" },
            { "CommandBar", "командная панель" }, { "ButtonGroup", "группа кнопок" }, { "Popup", "подменю" },
            { "HTMLDocumentField", "поле HTML" }, { "SpreadSheetDocumentField", "поле табличного документа" },
            { "TextDocumentField", "поле текстового документа" }, { "PictureField", "поле картинки" }, { "CalendarField", "поле календаря" },
            { "ColumnGroup", "группа колонок" }
        };

        static string Title(Dictionary<string, string> map, string key) { string v; return map.TryGetValue(key, out v) ? v : key; }

        static System.Xml.Linq.XDocument ParseXml(string text)
        {
            if (string.IsNullOrEmpty(text)) return null;
            try { return System.Xml.Linq.XDocument.Parse(text); } catch { return null; }
        }

        static string Short(string s)
        {
            s = Regex.Replace(s ?? "", @"\s+", " ").Trim();
            return s.Length > 120 ? s.Substring(0, 120) + "…" : s;
        }

        static string ValueOf(System.Xml.Linq.XElement e)
        {
            if (e == null) return "";
            var content = e.Descendants().FirstOrDefaultLocal("content");
            if (content != null) return Short(content.Value);
            if (e.HasElements) return "(составное значение)";
            return Short(e.Value);
        }

        static string XmlBody(string before, string after)
        {
            var xa = ParseXml(before);
            var xb = ParseXml(after);
            var root = (xb ?? xa);
            if (root == null) return "<div class=\"note\">Файл XML изменён.</div>";
            var rootName = root.Root.Name.LocalName;
            var items = new List<string>();
            if (rootName == "DataCompositionSchema") return QueryBody(xa, xb);
            if (rootName == "Form") FormChanges(xa, xb, items);
            else if (rootName == "MetaDataObject") ObjectChanges(xa, xb, items);
            if (items.Count == 0) return "<div class=\"note\">Изменены служебные данные описания (подробности — в XML).</div>";
            var sb = new StringBuilder("<ul class=\"list\">");
            foreach (var item in items) sb.Append("<li>").Append(H(item)).Append("</li>");
            return sb.Append("</ul>").ToString();
        }

        // Описание объекта метаданных: свойства, реквизиты, табличные части, формы, макеты, команды.
        static void ObjectChanges(System.Xml.Linq.XDocument xa, System.Xml.Linq.XDocument xb, List<string> items)
        {
            var oa = xa == null ? null : xa.Root.Elements().FirstOrDefault();
            var ob = xb == null ? null : xb.Root.Elements().FirstOrDefault();
            if (oa == null && ob != null) { items.Add("Объект добавлен"); }
            if (ob == null && oa != null) { items.Add("Объект удалён"); return; }
            if (ob == null) return;
            if (oa != null)
            {
                var pa = oa.Elements().FirstOrDefaultLocal("Properties");
                var pb = ob.Elements().FirstOrDefaultLocal("Properties");
                if (pa != null && pb != null)
                {
                    foreach (var e in pb.Elements())
                    {
                        var old = pa.Elements().FirstOrDefaultLocal(e.Name.LocalName);
                        if (old == null) { items.Add("Добавление свойства «" + PropTitle(e.Name.LocalName) + "»: " + ValueOf(e)); continue; }
                        if (!System.Xml.Linq.XNode.DeepEquals(old, e))
                            items.Add("Изменение свойства «" + PropTitle(e.Name.LocalName) + "»: " + ValueOf(old) + " → " + ValueOf(e));
                    }
                }
            }
            var ca = Children(oa);
            var cb = Children(ob);
            foreach (var key in cb.Keys)
            {
                if (!ca.ContainsKey(key)) items.Add("Добавление: " + Describe(key));
                else if (!System.Xml.Linq.XNode.DeepEquals(ca[key], cb[key])) items.Add("Изменение: " + Describe(key) + ChildDetails(ca[key], cb[key]));
            }
            foreach (var key in ca.Keys) if (!cb.ContainsKey(key)) items.Add("Удаление: " + Describe(key));
        }

        static readonly Dictionary<string, string> PropTitles = new Dictionary<string, string>
        {
            { "Synonym", "Синоним" }, { "Comment", "Комментарий" }, { "Type", "Тип" }, { "Title", "Заголовок" },
            { "Width", "Ширина" }, { "Height", "Высота" }, { "ToolTip", "Подсказка" }, { "Format", "Формат" },
            { "FillChecking", "Проверка заполнения" }, { "Indexing", "Индексирование" }, { "DefaultForm", "Основная форма" },
            { "ListPresentation", "Представление списка" }, { "ObjectPresentation", "Представление объекта" },
            { "Posting", "Проведение" }, { "RegisterRecords", "Движения" }, { "NumberLength", "Длина номера" },
            { "CodeLength", "Длина кода" }, { "DescriptionLength", "Длина наименования" }, { "Hierarchical", "Иерархический" },
            { "Owners", "Владельцы" }, { "BasedOn", "Ввод на основании" }, { "InputByString", "Ввод по строке" },
            { "DataLockControlMode", "Режим блокировки" }, { "FullTextSearch", "Полнотекстовый поиск" },
            { "MainDataCompositionSchema", "Основная схема компоновки" }, { "WindowOpeningMode", "Режим открытия окна" },
            { "AutoTitle", "Автозаголовок" }, { "CommandBarLocation", "Положение командной панели" }, { "Version", "Версия" }
        };

        static string PropTitle(string name) { string v; return PropTitles.TryGetValue(name, out v) ? v : name; }

        static string Describe(string key)
        {
            var parts = key.Split('|');
            return Title(ChildTitles, parts[0]) + " " + parts[1];
        }

        // Что поменялось у реквизита и т.п.: тип, синоним и другие свойства.
        static string ChildDetails(System.Xml.Linq.XElement a, System.Xml.Linq.XElement b)
        {
            var pa = a.Elements().FirstOrDefaultLocal("Properties");
            var pb = b.Elements().FirstOrDefaultLocal("Properties");
            if (pa == null || pb == null) return "";
            var names = new List<string>();
            foreach (var e in pb.Elements())
            {
                var old = pa.Elements().FirstOrDefaultLocal(e.Name.LocalName);
                if (old == null || !System.Xml.Linq.XNode.DeepEquals(old, e)) names.Add(PropTitle(e.Name.LocalName).ToLowerInvariant());
            }
            return names.Count == 0 ? "" : " (" + string.Join(", ", names.ToArray()) + ")";
        }

        static Dictionary<string, System.Xml.Linq.XElement> Children(System.Xml.Linq.XElement obj)
        {
            var result = new Dictionary<string, System.Xml.Linq.XElement>();
            if (obj == null) return result;
            var co = obj.Elements().FirstOrDefaultLocal("ChildObjects");
            if (co == null) return result;
            foreach (var e in co.Elements())
            {
                string name;
                var props = e.Elements().FirstOrDefaultLocal("Properties");
                var n = props == null ? null : props.Elements().FirstOrDefaultLocal("Name");
                name = n != null ? n.Value : e.Value;
                result[e.Name.LocalName + "|" + name] = e;
            }
            return result;
        }

        // Форма: элементы, реквизиты, команды, обработчики событий.
        static void FormChanges(System.Xml.Linq.XDocument xa, System.Xml.Linq.XDocument xb, List<string> items)
        {
            var ea = FormElements(xa);
            var eb = FormElements(xb);
            foreach (var key in eb.Keys)
            {
                if (!ea.ContainsKey(key)) items.Add("Добавление: " + DescribeForm(key));
                else if (!SameShallow(ea[key], eb[key])) items.Add("Изменение: " + DescribeForm(key));
            }
            foreach (var key in ea.Keys) if (!eb.ContainsKey(key)) items.Add("Удаление: " + DescribeForm(key));
            // Свойства самой формы: заголовок, размеры, режимы.
            if (xa != null && xb != null)
            {
                foreach (var e in xb.Root.Elements())
                {
                    if (e.HasElements && e.Name.LocalName != "Title") continue;
                    var old = xa.Root.Elements().FirstOrDefaultLocal(e.Name.LocalName);
                    if (old == null) items.Add("Добавление свойства формы «" + PropTitle(e.Name.LocalName) + "»: " + ValueOf(e));
                    else if (!System.Xml.Linq.XNode.DeepEquals(old, e)) items.Add("Изменение свойства формы «" + PropTitle(e.Name.LocalName) + "»: " + ValueOf(old) + " → " + ValueOf(e));
                }
            }
            var va = Events(xa);
            var vb = Events(xb);
            foreach (var key in vb.Keys)
            {
                string old;
                if (!va.TryGetValue(key, out old)) items.Add("Добавлен обработчик события " + key + ": " + vb[key]);
                else if (old != vb[key]) items.Add("Изменён обработчик события " + key + ": " + old + " → " + vb[key]);
            }
            foreach (var key in va.Keys) if (!vb.ContainsKey(key)) items.Add("Удалён обработчик события " + key);
        }

        static string DescribeForm(string key)
        {
            var parts = key.Split('|');
            if (parts[0] == "attr") return "реквизит формы " + parts[1];
            if (parts[0] == "cmd") return "команда формы " + parts[1];
            return "элемент формы: " + Title(ItemTitles, parts[0]) + " " + parts[1];
        }

        // Элемент формы без вложенных элементов: его собственные свойства, а не содержимое групп.
        static bool SameShallow(System.Xml.Linq.XElement a, System.Xml.Linq.XElement b)
        {
            var ca = new System.Xml.Linq.XElement(a);
            var cb = new System.Xml.Linq.XElement(b);
            foreach (var x in ca.Elements().Where(e => e.Name.LocalName == "ChildItems").ToList()) x.Remove();
            foreach (var x in cb.Elements().Where(e => e.Name.LocalName == "ChildItems").ToList()) x.Remove();
            return System.Xml.Linq.XNode.DeepEquals(ca, cb);
        }

        static Dictionary<string, System.Xml.Linq.XElement> FormElements(System.Xml.Linq.XDocument doc)
        {
            var result = new Dictionary<string, System.Xml.Linq.XElement>();
            if (doc == null) return result;
            foreach (var e in doc.Root.Descendants())
            {
                var name = (string)e.Attribute("name");
                if (name == null) continue;
                var local = e.Name.LocalName;
                var parent = e.Parent == null ? "" : e.Parent.Name.LocalName;
                if (local == "Attribute" && parent == "Attributes") result["attr|" + name] = e;
                else if (local == "Command" && parent == "Commands") result["cmd|" + name] = e;
                else if (local == "Event" || local == "ContextMenu" || local == "ExtendedTooltip" || local.EndsWith("Addition") || local == "AutoCommandBar" || local == "Column") continue;
                else result[local + "|" + name] = e;
            }
            return result;
        }

        static Dictionary<string, string> Events(System.Xml.Linq.XDocument doc)
        {
            var result = new Dictionary<string, string>();
            if (doc == null) return result;
            foreach (var e in doc.Root.Descendants().Where(x => x.Name.LocalName == "Event"))
            {
                var owner = e.Parent == null || e.Parent.Parent == null ? "" : ((string)e.Parent.Parent.Attribute("name") ?? "форма");
                result[owner + "." + (string)e.Attribute("name")] = e.Value;
            }
            return result;
        }

        // СКД: тексты запросов наборов данных показываем как код, остальное — списком.
        static string QueryBody(System.Xml.Linq.XDocument xa, System.Xml.Linq.XDocument xb)
        {
            var qa = Queries(xa);
            var qb = Queries(xb);
            var sb = new StringBuilder();
            foreach (var key in qb.Keys.Union(qa.Keys))
            {
                string a, b;
                qa.TryGetValue(key, out a);
                qb.TryGetValue(key, out b);
                if (a == b) continue;
                var la = Differ.SplitLines(a ?? "");
                var lb = Differ.SplitLines(b ?? "");
                var ops = Differ.Compare(la, lb);
                var status = a == null ? "добавлен" : b == null ? "удалён" : "изменён";
                sb.Append(Header("mh", "Запрос набора данных " + key, status));
                sb.Append("<div class=\"mb code\">").Append(RenderOps(ops, la, lb, true)).Append("</div>");
            }
            if (sb.Length == 0) sb.Append("<div class=\"note\">Изменены настройки схемы компоновки данных (поля, параметры, варианты) — подробности в XML.</div>");
            return sb.ToString();
        }

        static Dictionary<string, string> Queries(System.Xml.Linq.XDocument doc)
        {
            var result = new Dictionary<string, string>();
            if (doc == null) return result;
            foreach (var q in doc.Root.Descendants().Where(x => x.Name.LocalName == "query"))
            {
                var set = q.Parent;
                var nameEl = set == null ? null : set.Elements().FirstOrDefaultLocal("name");
                var name = nameEl == null ? "запрос" : nameEl.Value;
                result[name] = q.Value.Replace("\r\n", "\n");
            }
            return result;
        }
    }

    static class XmlExt
    {
        public static System.Xml.Linq.XElement FirstOrDefaultLocal(this IEnumerable<System.Xml.Linq.XElement> list, string localName)
        {
            foreach (var e in list) if (e.Name.LocalName == localName) return e;
            return null;
        }
    }
}
