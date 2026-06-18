import os
import random

prefixes = ["用科技", "以智能", "借AI", "让机器人", "凭创新", "汇聚骅羲力量", "秉持科技向善", "深耕智慧养老", "用我们的技术", "打造最强机器人"]
actions = ["守护", "温暖", "点亮", "照亮", "关爱", "赋能", "助力", "陪伴", "呵护", "拥抱"]
targets = ["银发岁月", "晚年生活", "长者时光", "养老事业", "每一个家庭", "老龄化社会", "每一位老人", "金色年华", "长寿时代", "夕阳红"]
results = ["，让爱不再缺席。", "，创造更美好的明天。", "，做最有温度的科技公司。", "，铸就养老新标准。", "，让生命更有尊严。", "，传递智能的关怀。", "，开启智慧养老新纪元。", "，让科技真正造福人类。", "，做长者最贴心的家人。", "，书写陪伴的新篇章。"]

quotes = set()
while len(quotes) < 100:
    q = random.choice(prefixes) + random.choice(actions) + random.choice(targets) + random.choice(results)
    quotes.add(q)

os.makedirs('lib/utils', exist_ok=True)
with open('lib/utils/motivational_quotes.dart', 'w', encoding='utf-8') as f:
    f.write('const List<String> motivationalQuotes = [\n')
    for q in list(quotes):
        f.write(f'  "{q}",\n')
    f.write('];\n')
