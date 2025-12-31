#!/usr/bin/env python3
"""
KPK Shares Coverage Analysis Script

This script provides detailed coverage analysis specifically for the kpkShares contract
and related test files, focusing on the most important coverage metrics.
"""

import re
import sys
from pathlib import Path
from typing import Dict, List, Optional
from dataclasses import dataclass


@dataclass
class FunctionCoverage:
    """Represents function coverage data"""
    name: str
    line: int
    calls: int
    status: str  # 'covered', 'uncovered', 'partially_covered'


@dataclass
class LineCoverage:
    """Represents line coverage data"""
    line: int
    hits: int


@dataclass
class BranchCoverage:
    """Represents branch coverage data"""
    line: int
    block: int
    branch: int
    hits: int


@dataclass
class FileCoverage:
    """Represents file coverage data"""
    filename: str
    functions: List[FunctionCoverage]
    lines: List[LineCoverage]
    branches: List[BranchCoverage]
    summary: Dict[str, int]


class KpkSharesCoverageAnalyzer:
    """Specialized analyzer for kpkShares contract coverage"""
    
    def __init__(self, lcov_file: str):
        self.lcov_file = lcov_file
        self.files: Dict[str, FileCoverage] = {}
        self.current_file: Optional[FileCoverage] = None
        self.kpk_shares_file: Optional[FileCoverage] = None
        
    def parse(self) -> None:
        """Parse the LCOV file"""
        try:
            with open(self.lcov_file, 'r') as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                        
                    if line.startswith('SF:'):
                        self._parse_source_file(line)
                    elif line.startswith('FN:'):
                        self._parse_function(line)
                    elif line.startswith('FNDA:'):
                        self._parse_function_data(line)
                    elif line.startswith('DA:'):
                        self._parse_line_data(line)
                    elif line.startswith('BRDA:'):
                        self._parse_branch_data(line)
                    elif line.startswith('FNF:'):
                        self._parse_summary(line, 'FNF')
                    elif line.startswith('FNH:'):
                        self._parse_summary(line, 'FNH')
                    elif line.startswith('LF:'):
                        self._parse_summary(line, 'LF')
                    elif line.startswith('LH:'):
                        self._parse_summary(line, 'LH')
                    elif line.startswith('BRF:'):
                        self._parse_summary(line, 'BRF')
                    elif line.startswith('BRH:'):
                        self._parse_summary(line, 'BRH')
                        
        except FileNotFoundError:
            print(f"Error: File {self.lcov_file} not found")
            sys.exit(1)
        except Exception as e:
            print(f"Error parsing file: {e}")
            sys.exit(1)
    
    def _parse_source_file(self, line: str) -> None:
        """Parse source file line"""
        filename = line[3:]  # Remove 'SF:' prefix
        self.current_file = FileCoverage(
            filename=filename,
            functions=[],
            lines=[],
            branches=[],
            summary={'FNF': 0, 'FNH': 0, 'LF': 0, 'LH': 0, 'BRF': 0, 'BRH': 0}
        )
        self.files[filename] = self.current_file
        
        # Track kpkShares specifically
        if 'kpkShares.sol' in filename:
            self.kpk_shares_file = self.current_file
    
    def _parse_function(self, line: str) -> None:
        """Parse function line"""
        if not self.current_file:
            return
            
        # Format: FN:line,function_name
        match = re.match(r'FN:(\d+),(.+)', line)
        if match:
            line_num, func_name = match.groups()
            func = FunctionCoverage(
                name=func_name,
                line=int(line_num),
                calls=0,
                status='uncovered'
            )
            self.current_file.functions.append(func)
    
    def _parse_function_data(self, line: str) -> None:
        """Parse function data line"""
        if not self.current_file:
            return
            
        # Format: FNDA:calls,function_name
        match = re.match(r'FNDA:(\d+),(.+)', line)
        if match:
            calls, func_name = match.groups()
            # Find matching function and update calls
            for func in self.current_file.functions:
                if func.name == func_name:
                    func.calls = int(calls)
                    func.status = 'covered' if int(calls) > 0 else 'uncovered'
                    break
    
    def _parse_line_data(self, line: str) -> None:
        """Parse line data"""
        if not self.current_file:
            return
            
        # Format: DA:line,hits
        match = re.match(r'DA:(\d+),(\d+)', line)
        if match:
            line_num, hits = match.groups()
            line_cov = LineCoverage(
                line=int(line_num),
                hits=int(hits)
            )
            self.current_file.lines.append(line_cov)
    
    def _parse_branch_data(self, line: str) -> None:
        """Parse branch data"""
        if not self.current_file:
            return
            
        # Format: BRDA:line,block,branch,hits
        match = re.match(r'BRDA:(\d+),(\d+),(\d+),(\d+|-)', line)
        if match:
            line_num, block, branch, hits = match.groups()
            branch_cov = BranchCoverage(
                line=int(line_num),
                block=int(block),
                branch=int(branch),
                hits=int(hits) if hits != '-' else 0
            )
            self.current_file.branches.append(branch_cov)
    
    def _parse_summary(self, line: str, key: str) -> None:
        """Parse summary line"""
        if not self.current_file:
            return
            
        # Format: KEY:value
        value = line.split(':', 1)[1]
        self.current_file.summary[key] = int(value)
    
    def generate_kpk_shares_report(self) -> str:
        """Generate detailed kpkShares coverage report"""
        if not self.kpk_shares_file:
            return "kpkShares.sol not found in coverage data"
        
        file_cov = self.kpk_shares_file
        report = []
        
        # Header
        report.append("=" * 80)
        report.append("KPK SHARES CONTRACT COVERAGE ANALYSIS")
        report.append("=" * 80)
        report.append("")
        
        # Overall statistics
        total_functions = len(file_cov.functions)
        covered_functions = len([f for f in file_cov.functions if f.calls > 0])
        uncovered_functions = total_functions - covered_functions
        
        total_lines = len(file_cov.lines)
        covered_lines = len([l for l in file_cov.lines if l.hits > 0])
        uncovered_lines = total_lines - covered_lines
        
        total_branches = len(file_cov.branches)
        covered_branches = len([b for b in file_cov.branches if b.hits > 0])
        uncovered_branches = total_branches - covered_branches
        
        func_coverage = (covered_functions / total_functions * 100) if total_functions > 0 else 0
        line_coverage = (covered_lines / total_lines * 100) if total_lines > 0 else 0
        branch_coverage = (covered_branches / total_branches * 100) if total_branches > 0 else 0
        
        report.append("OVERALL COVERAGE STATISTICS")
        report.append("-" * 40)
        report.append(f"Function Coverage: {func_coverage:.1f}% ({covered_functions}/{total_functions})")
        report.append(f"Line Coverage: {line_coverage:.1f}% ({covered_lines}/{total_lines})")
        report.append(f"Branch Coverage: {branch_coverage:.1f}% ({covered_branches}/{total_branches})")
        report.append("")
        
        # Function breakdown by category
        report.append("FUNCTION BREAKDOWN BY CATEGORY")
        report.append("-" * 40)
        
        # Group functions by category
        categories = {
            'Core Operations': ['requestSubscription', 'requestRedemption', 'processSubscriptionRequests', 'processRedemptionRequests'],
            'Preview Functions': ['previewSubscription', 'previewRedemption'],
            'Asset Management': ['updateAsset', 'getApprovedAssets', 'getApprovedAsset', 'isApprovedAsset'],
            'Fee Management': ['_chargeFees', '_chargeManagementFee', '_chargePerformanceFee', '_chargeRedemptionFee'],
            'Request Management': ['cancelSubscription', 'cancelRedemption', 'updateSubscriptionRequest', 'updateRedemptionRequest'],
            'Configuration': ['setSubscriptionRequestTtl', 'setRedemptionRequestTtl', 'setUpdateRequestTtl', 'setFeeReceiver', 'setManagementFeeRate', 'setRedemptionFeeRate', 'setPerformanceFeeRate', 'setPerfFeeModule'],
            'Utility Functions': ['assetsToShares', 'sharesToAssets', 'assetDecimals', 'getRequest'],
            'Internal Helpers': ['_validateInitializationParams', '_initializeState', '_setupRoles', '_validateRequestParams', '_validateRequestUpdate', '_validateCancellationAuthorization', '_validateDepositRequest', '_validateRedeemRequest'],
            'Upgrade Functions': ['_authorizeUpgrade']
        }
        
        # Initialize empty lists for each category
        categorized_functions = {category: [] for category in categories.keys()}
        categorized_functions['Uncovered Functions'] = []
        
        # Categorize functions
        for func in file_cov.functions:
            categorized = False
            for category, patterns in categories.items():
                if any(pattern in func.name for pattern in patterns):
                    categorized_functions[category].append(func)
                    categorized = True
                    break
            
            if not categorized:
                categorized_functions['Uncovered Functions'].append(func)
        
        # Display categories
        for category, funcs in categorized_functions.items():
            if not funcs:
                continue
                
            covered_in_category = len([f for f in funcs if f.calls > 0])
            total_in_category = len(funcs)
            coverage_pct = (covered_in_category / total_in_category * 100) if total_in_category > 0 else 0
            
            report.append(f"\n{category}: {coverage_pct:.1f}% ({covered_in_category}/{total_in_category})")
            
            # Show uncovered functions in this category
            uncovered_in_category = [f for f in funcs if f.calls == 0]
            if uncovered_in_category:
                report.append(f"  Uncovered: {', '.join(f.name for f in uncovered_in_category)}")
        
        # Most called functions
        report.append("\n" + "=" * 80)
        report.append("MOST CALLED FUNCTIONS (All Functions)")
        report.append("=" * 80)
        
        sorted_funcs = sorted(file_cov.functions, key=lambda x: x.calls, reverse=True)
        for i, func in enumerate(sorted_funcs, 1):
            status = "✓" if func.calls > 0 else "✗"
            report.append(f"{i:2d}. {status} {func.name:<35} (line {func.line:3d}): {func.calls:4d} calls")
        
        # Uncovered functions
        report.append("\n" + "=" * 80)
        report.append("UNCOVERED FUNCTIONS")
        report.append("=" * 80)
        
        uncovered_funcs = [f for f in file_cov.functions if f.calls == 0]
        if uncovered_funcs:
            for func in uncovered_funcs:
                report.append(f"✗ {func.name} (line {func.line})")
        else:
            report.append("All functions are covered! 🎉")
        
        # Coverage gaps analysis
        report.append("\n" + "=" * 80)
        report.append("COVERAGE GAPS ANALYSIS")
        report.append("=" * 80)
        
        uncovered_lines = [l for l in file_cov.lines if l.hits == 0]
        if uncovered_lines:
            report.append(f"Total uncovered lines: {len(uncovered_lines)}")
            report.append("Uncovered line ranges:")
            
            # Group consecutive lines
            ranges = []
            start = uncovered_lines[0].line
            prev = start
            
            for line in uncovered_lines[1:]:
                if line.line != prev + 1:
                    ranges.append((start, prev))
                    start = line.line
                prev = line.line
            ranges.append((start, prev))
            
            for start_line, end_line in ranges:  # Show all ranges
                if start_line == end_line:
                    report.append(f"  Line {start_line}")
                else:
                    report.append(f"  Lines {start_line}-{end_line}")
        else:
            report.append("All lines are covered! 🎉")
        
        # Recommendations
        report.append("\n" + "=" * 80)
        report.append("COVERAGE IMPROVEMENT RECOMMENDATIONS")
        report.append("=" * 80)
        
        if uncovered_functions > 0:
            report.append(f"• {uncovered_functions} functions need test coverage")
        
        if len(uncovered_lines) > 0:
            report.append(f"• {len(uncovered_lines)} lines need test coverage")
            
        if uncovered_branches > 0:
            report.append(f"• {uncovered_branches} branches need test coverage")
        
        if uncovered_functions == 0 and uncovered_lines == 0 and uncovered_branches == 0:
            report.append("• Excellent coverage! Consider adding edge case tests")
        else:
            report.append("• Focus on uncovered functions first, then lines, then branches")
            report.append("• Consider adding integration tests for complex scenarios")
            report.append("• Review error handling paths and edge cases")
        
        return "\n".join(report)
    
    def generate_test_files_report(self) -> str:
        """Generate report for test files coverage"""
        test_files = {k: v for k, v in self.files.items() if 'test/' in k and 'kpkShares' in k}
        
        if not test_files:
            return "No kpkShares test files found in coverage data"
        
        report = []
        report.append("=" * 80)
        report.append("KPK SHARES TEST FILES COVERAGE")
        report.append("=" * 80)
        report.append("")
        
        for filename, file_cov in sorted(test_files.items()):
            total_functions = len(file_cov.functions)
            covered_functions = len([f for f in file_cov.functions if f.calls > 0])
            coverage_pct = (covered_functions / total_functions * 100) if total_functions > 0 else 0
            
            report.append(f"{filename}")
            report.append(f"  Function Coverage: {coverage_pct:.1f}% ({covered_functions}/{total_functions})")
            
            # Show uncovered test functions
            uncovered_funcs = [f for f in file_cov.functions if f.calls == 0]
            if uncovered_funcs:
                report.append(f"  Uncovered Test Functions: {', '.join(f.name for f in uncovered_funcs)}")
            report.append("")
        
        return "\n".join(report)


def main():
    """Main function"""
    if len(sys.argv) != 2:
        print("Usage: python analyze_kpkShares_coverage.py <lcov.info>")
        print("Example: python analyze_kpkShares_coverage.py lcov.info")
        sys.exit(1)
    
    lcov_file = sys.argv[1]
    
    if not Path(lcov_file).exists():
        print(f"Error: File {lcov_file} not found")
        sys.exit(1)
    
    analyzer = KpkSharesCoverageAnalyzer(lcov_file)
    analyzer.parse()
    
    # Generate kpkShares specific report
    kpk_report = analyzer.generate_kpk_shares_report()
    print(kpk_report)
    
    # Generate test files report
    test_report = analyzer.generate_test_files_report()
    print("\n" + test_report)
    
    # Save reports to files in the same directory as the script
    script_dir = Path(__file__).parent
    output_file = script_dir / "kpkShares_coverage_report.txt"
    
    with open(output_file, 'w') as f:
        f.write(kpk_report)
        f.write("\n\n" + test_report)
    
    print(f"\nDetailed report saved to: {output_file}")


if __name__ == "__main__":
    main()
