import Foundation

@main
struct TodoDateResolverSmoke {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Hong_Kong")!

        // 2026-07-14 是周二，“本周三”应确定为 7 月 15 号。
        let tuesdayNoon = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 7, day: 14, hour: 12
        ))!
        let weekly = TodoDateResolver.resolve("本周三见文总", spokenAt: tuesdayNoon, calendar: calendar)
        precondition(weekly?.normalizedText == "7月15号见文总")
        precondition(calendar.component(.day, from: weekly!.startDate) == 15)
        precondition(weekly?.isAllDay == true)

        // 不带“本/这/下”的星期几，统一按录音发生时所在的本周换算。
        let bareWeekday = TodoDateResolver.resolve("周四我要去进行某某活动", spokenAt: tuesdayNoon, calendar: calendar)
        precondition(bareWeekday?.normalizedText == "7月16号我要去进行某某活动")
        precondition(calendar.component(.day, from: bareWeekday!.startDate) == 16)

        let bareXingqi = TodoDateResolver.resolve("星期四见客户", spokenAt: tuesdayNoon, calendar: calendar)
        precondition(bareXingqi?.normalizedText == "7月16号见客户")

        let bareLibai = TodoDateResolver.resolve("礼拜四见客户", spokenAt: tuesdayNoon, calendar: calendar)
        precondition(bareLibai?.normalizedText == "7月16号见客户")

        // 明确说“下周”仍然是下一周，不能被裸“周四”规则吞掉。
        let nextWeek = TodoDateResolver.resolve("下周四见客户", spokenAt: tuesdayNoon, calendar: calendar)
        precondition(nextWeek?.normalizedText == "7月23号见客户")

        let nextTuesday = TodoDateResolver.resolve("下周二提交方案", spokenAt: tuesdayNoon, calendar: calendar)
        precondition(nextTuesday?.normalizedText == "7月21号提交方案")
        precondition(calendar.component(.day, from: nextTuesday!.startDate) == 21)

        // 叠加的“下下”表示两周后，且星期/礼拜变体与“周”同义。
        let weekAfterNext = TodoDateResolver.resolve("下下周三跟进项目", spokenAt: tuesdayNoon, calendar: calendar)
        precondition(weekAfterNext?.normalizedText == "7月29号跟进项目")
        precondition(calendar.component(.day, from: weekAfterNext!.startDate) == 29)
        precondition(TodoDateResolver.resolve("下下星期三跟进项目", spokenAt: tuesdayNoon, calendar: calendar)?.normalizedText
                     == "7月29号跟进项目")

        // 即使本周该星期已经过去，“周四”仍按产品约定指本周，而不是擅自顺延到下周。
        let fridayNoon = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 7, day: 17, hour: 12
        ))!
        let passedThisWeek = TodoDateResolver.resolve("周四复盘", spokenAt: fridayNoon, calendar: calendar)
        precondition(passedThisWeek?.normalizedText == "7月16号复盘")

        // “上周/每周”不是本次单次日程规则，不应被内部的“周四”误匹配。
        precondition(TodoDateResolver.resolve("上周四复盘", spokenAt: tuesdayNoon, calendar: calendar) == nil)
        precondition(TodoDateResolver.resolve("每周四复盘", spokenAt: tuesdayNoon, calendar: calendar) == nil)

        // 周一深夜跨过零点后的周二 02:00，语义上仍以周一为基准；
        // 此时说“明天”应得到周二 7 月 14 号，不是周三。
        let tuesdayTwoAM = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 7, day: 14, hour: 2
        ))!
        let lateNight = TodoDateResolver.resolve("明天下午3点见物理治疗师", spokenAt: tuesdayTwoAM, calendar: calendar)
        precondition(lateNight?.normalizedText == "7月14号下午3点见物理治疗师")
        precondition(calendar.component(.day, from: lateNight!.startDate) == 14)
        precondition(calendar.component(.hour, from: lateNight!.startDate) == 15)
        precondition(lateNight?.isAllDay == false)

        // 凌晨 3:00 起正式换日，同样的“明天”应指向 7 月 15 号。
        let tuesdayThreeAM = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 7, day: 14, hour: 3
        ))!
        let afterCutoff = TodoDateResolver.resolve("明天做事", spokenAt: tuesdayThreeAM, calendar: calendar)
        precondition(afterCutoff?.normalizedText == "7月15号做事")

        // 2026-08-06:口述出来的时间几乎都是中文数字。此前 parseTime 只认阿拉伯数字,
        // "明天下午三点见李想"的时间被整条丢掉、日历事件建成全天(实测证实)。
        func time(_ text: String) -> (hour: Int, minute: Int, allDay: Bool)? {
            guard let plan = TodoDateResolver.resolve(text, spokenAt: tuesdayNoon, calendar: calendar) else { return nil }
            return (calendar.component(.hour, from: plan.startDate),
                    calendar.component(.minute, from: plan.startDate),
                    plan.isAllDay)
        }
        precondition(time("明天下午三点见李想")! == (15, 0, false))
        precondition(time("明天两点半开会")! == (2, 30, false))
        precondition(time("明天下午两点半开会")! == (14, 30, false))
        precondition(time("明天晚上八点回电话")! == (20, 0, false))
        precondition(time("明天上午十点提交材料")! == (10, 0, false))
        precondition(time("明天十一点二十开始路演")! == (11, 20, false))
        precondition(time("明天中午十二点半吃饭")! == (12, 30, false))
        // 阿拉伯数字与冒号写法不得因此回归。
        precondition(time("明天下午3点见李想")! == (15, 0, false))
        precondition(time("明天下午3:30见李想")! == (15, 30, false))
        // "第三点"是枚举序号,不是三点钟——只能落成全天。
        precondition(time("明天讨论第三点")! == (0, 0, true))
        // 没说时间仍然是全天。
        precondition(time("明天做事")! == (0, 0, true))

        // 2026-08-07:取消「完成」时要把日历事项建回来,重建的锚点必须是待办的 createdAt,
        // 不能是"现在"。文字里已是「8月7号」这种不带年份的具体日期,以当下为锚点解析时,
        // 已经过去的日期会被推到**明年**,于是建出一个错年份的日程。
        let created = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 8, day: 6, hour: 22
        ))!
        let dated = "8月7号下午三点见李想"
        let byCreatedAt = TodoDateResolver.resolve(dated, spokenAt: created, calendar: calendar)!
        precondition(calendar.component(.year, from: byCreatedAt.startDate) == 2026)
        precondition(calendar.component(.month, from: byCreatedAt.startDate) == 8)
        precondition(calendar.component(.day, from: byCreatedAt.startDate) == 7)
        precondition(calendar.component(.hour, from: byCreatedAt.startDate) == 15)
        // 反例:同一段文字用一个月后的时刻当锚点,会滚到 2027 —— 这正是要避免的。
        let later = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 9, day: 1, hour: 10
        ))!
        let byNow = TodoDateResolver.resolve(dated, spokenAt: later, calendar: calendar)!
        precondition(calendar.component(.year, from: byNow.startDate) == 2027)

        print("PASS: todo date resolver smoke tests")
    }
}
