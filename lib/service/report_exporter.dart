import 'dart:io';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ros_flutter_gui_app/page/patrol_test_page.dart';

class ReportExporter {
  static Future<String?> exportToHtml(List<PatrolReport> reports) async {
    try {
      final htmlContent = _generateHtml(reports);
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final defaultFileName = 'PatrolReport_$timestamp.html';
      
      String? savePath;
      
      try {
        savePath = await FilePicker.platform.saveFile(
          dialogTitle: '保存巡逻测试报告',
          fileName: defaultFileName,
          type: FileType.custom,
          allowedExtensions: ['html'],
        );
      } catch (e) {
        print("saveFile error: $e");
      }
      
      if (savePath == null && (Platform.isAndroid || Platform.isIOS)) {
        try {
          String? selectedDir = await FilePicker.platform.getDirectoryPath(
            dialogTitle: '选择保存报告的目录',
          );
          if (selectedDir != null) {
            savePath = '$selectedDir/$defaultFileName';
          }
        } catch (e) {
          print("getDirectoryPath error: $e");
        }
      }
      
      if (savePath == null) {
        return null; // 用户取消了保存
      }

      final file = File(savePath);
      await file.writeAsString(htmlContent);
      return file.path;
    } catch (e) {
      print('Export HTML Error: $e');
      return null;
    }
  }

  static String _generateHtml(List<PatrolReport> reports) {
    final dateFormat = DateFormat('yyyy-MM-dd HH:mm:ss');
    
    int totalReports = reports.length;
    int totalPoints = 0;
    int totalSuccess = 0;
    
    for (var r in reports) {
      totalPoints += r.totalPointsCount;
      totalSuccess += r.successCount;
    }
    
    double avgSuccess = totalPoints > 0 ? (totalSuccess / totalPoints) * 100 : 0.0;

    String reportsHtml = '';
    for (var i = 0; i < reports.length; i++) {
      final report = reports[i];
      final startTime = dateFormat.format(report.startTime);
      final endTime = report.endTime != null ? dateFormat.format(report.endTime!) : 'N/A';
      
      String rowsHtml = '';
      for (var log in report.pointLogs) {
        String statusColor = '#94A3B8';
        if (log.status == 'Finished') statusColor = '#10B981'; // Green
        else if (log.status == 'Error' || log.status == 'Failed' || log.status == 'Timeout') statusColor = '#F43F5E'; // Red
        else if (log.status == 'Navigating') statusColor = '#3B82F6'; // Blue
        
        rowsHtml += '''
          <tr>
            <td>${log.roundIndex}</td>
            <td>${log.pointName}</td>
            <td>${log.pointType}</td>
            <td><span class="status-badge" style="background-color: ${statusColor}20; color: $statusColor; border-color: $statusColor;">${log.status}</span></td>
            <td>${(log.durationMs / 1000).toStringAsFixed(1)}s</td>
            <td class="error-text">${log.errorMessage}</td>
          </tr>
        ''';
      }

      reportsHtml += '''
        <div class="report-card">
          <div class="report-header" onclick="toggleDetails('details-$i')">
            <div class="report-title">
              <span class="report-icon">📄</span>
              <h3>巡逻报告 - $startTime</h3>
            </div>
            <div class="report-meta">
              <span class="meta-item">巡逻遍数: ${report.completedRounds} / ${report.totalRounds}</span>
              <span class="meta-item">成功率: ${report.successRate.toStringAsFixed(1)}%</span>
              <span class="meta-item">耗时: ${report.endTime != null ? report.endTime!.difference(report.startTime).inSeconds : 0}s</span>
              <span class="toggle-icon">▼</span>
            </div>
          </div>
          <div class="report-details" id="details-$i">
            <table class="data-table">
              <thead>
                <tr>
                  <th>轮次</th>
                  <th>目标点位</th>
                  <th>类型</th>
                  <th>状态</th>
                  <th>耗时</th>
                  <th>错误信息</th>
                </tr>
              </thead>
              <tbody>
                $rowsHtml
              </tbody>
            </table>
          </div>
        </div>
      ''';
    }

    return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>自动化巡逻测试报告</title>
    <style>
        :root {
            --bg-color: #0F172A;
            --card-bg: #1E293B;
            --text-primary: #F8FAFC;
            --text-secondary: #94A3B8;
            --accent: #38BDF8;
            --success: #10B981;
            --danger: #F43F5E;
            --border: #334155;
        }
        
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
            font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
        }
        
        body {
            background-color: var(--bg-color);
            color: var(--text-primary);
            line-height: 1.6;
            padding: 2rem;
        }
        
        .container {
            max-width: 1200px;
            margin: 0 auto;
        }
        
        .header {
            text-align: center;
            margin-bottom: 3rem;
            animation: fadeInDown 0.8s ease;
        }
        
        .header h1 {
            font-size: 2.5rem;
            background: linear-gradient(to right, #38BDF8, #818CF8);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            margin-bottom: 1rem;
        }
        
        .summary-dashboard {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 1.5rem;
            margin-bottom: 3rem;
            animation: fadeIn 1s ease;
        }
        
        .summary-card {
            background: var(--card-bg);
            border-radius: 1rem;
            padding: 1.5rem;
            border: 1px solid var(--border);
            text-align: center;
            box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06);
            transition: transform 0.3s ease, border-color 0.3s ease;
        }
        
        .summary-card:hover {
            transform: translateY(-5px);
            border-color: var(--accent);
        }
        
        .summary-value {
            font-size: 2rem;
            font-weight: bold;
            color: var(--text-primary);
            margin: 0.5rem 0;
        }
        
        .summary-label {
            color: var(--text-secondary);
            font-size: 0.9rem;
            text-transform: uppercase;
            letter-spacing: 1px;
        }
        
        .report-card {
            background: var(--card-bg);
            border-radius: 1rem;
            margin-bottom: 1.5rem;
            border: 1px solid var(--border);
            overflow: hidden;
            animation: fadeInUp 0.8s ease;
        }
        
        .report-header {
            padding: 1.5rem;
            display: flex;
            justify-content: space-between;
            align-items: center;
            cursor: pointer;
            background: rgba(255, 255, 255, 0.02);
            transition: background 0.3s ease;
        }
        
        .report-header:hover {
            background: rgba(255, 255, 255, 0.05);
        }
        
        .report-title {
            display: flex;
            align-items: center;
            gap: 1rem;
        }
        
        .report-meta {
            display: flex;
            align-items: center;
            gap: 1.5rem;
            color: var(--text-secondary);
            font-size: 0.95rem;
        }
        
        .meta-item {
            background: rgba(0, 0, 0, 0.2);
            padding: 0.25rem 0.75rem;
            border-radius: 2rem;
        }
        
        .report-details {
            display: none;
            padding: 0 1.5rem 1.5rem 1.5rem;
            border-top: 1px solid var(--border);
        }
        
        .data-table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 1rem;
        }
        
        .data-table th, .data-table td {
            padding: 1rem;
            text-align: left;
            border-bottom: 1px solid var(--border);
        }
        
        .data-table th {
            color: var(--text-secondary);
            font-weight: 600;
            text-transform: uppercase;
            font-size: 0.85rem;
            letter-spacing: 0.5px;
        }
        
        .data-table tr {
            transition: background 0.2s ease;
        }
        
        .data-table tr:hover {
            background: rgba(255, 255, 255, 0.02);
        }
        
        .status-badge {
            padding: 0.25rem 0.75rem;
            border-radius: 2rem;
            font-size: 0.85rem;
            font-weight: 600;
            border: 1px solid transparent;
        }
        
        .error-text {
            color: var(--danger);
            font-size: 0.9rem;
        }
        
        @keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
        @keyframes fadeInDown {
            from { opacity: 0; transform: translateY(-20px); }
            to { opacity: 1; transform: translateY(0); }
        }
        @keyframes fadeInUp {
            from { opacity: 0; transform: translateY(20px); }
            to { opacity: 1; transform: translateY(0); }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>自动化巡逻测试报告</h1>
            <p style="color: var(--text-secondary);">导出时间: ${dateFormat.format(DateTime.now())}</p>
        </div>
        
        <div class="summary-dashboard">
            <div class="summary-card">
                <div class="summary-label">总计测试次数</div>
                <div class="summary-value" style="color: var(--accent);">$totalReports</div>
            </div>
            <div class="summary-card">
                <div class="summary-label">总计执行点位</div>
                <div class="summary-value">$totalPoints</div>
            </div>
            <div class="summary-card">
                <div class="summary-label">总体成功率</div>
                <div class="summary-value" style="color: ${avgSuccess > 80 ? 'var(--success)' : (avgSuccess > 50 ? '#F59E0B' : 'var(--danger)')};">${avgSuccess.toStringAsFixed(1)}%</div>
            </div>
        </div>
        
        <div class="reports-list">
            $reportsHtml
        </div>
    </div>
    
    <script>
        function toggleDetails(id) {
            const el = document.getElementById(id);
            if (el.style.display === 'block') {
                el.style.display = 'none';
            } else {
                el.style.display = 'block';
            }
        }
    </script>
</body>
</html>
    ''';
  }
}
