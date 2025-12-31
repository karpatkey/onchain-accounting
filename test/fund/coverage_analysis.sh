#!/bin/bash

# Coverage Analysis Script Wrapper
# This script provides easy access to coverage analysis tools

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Path to lcov.info relative to project root
LCOV_FILE="./lcov.info"

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to show usage
show_usage() {
    echo "Coverage Analysis Tool"
    echo ""
    echo "Usage: $0 [OPTIONS] [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  full          Generate full coverage report for all files"
    echo "  kpk           Generate detailed kpkShares coverage report"
    echo "  summary       Show quick coverage summary"
    echo "  update        Update lcov.info with current test coverage"
    echo ""
    echo "Options:"
    echo "  -f, --file    Specify lcov.info file (default: lcov.info)"
    echo "  -h, --help    Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 full                    # Full coverage report"
    echo "  $0 kpk                     # kpkShares focused report"
    echo "  $0 -f contracts/custom.info full  # Use custom lcov file (relative to project root)"
    echo "  $0 update                  # Update coverage data"
}

# Function to check dependencies
check_dependencies() {
    if ! command -v python3 &> /dev/null; then
        print_error "Python3 is required but not installed"
        exit 1
    fi
    
    if ! command -v forge &> /dev/null; then
        print_warning "Foundry not found in PATH. Some commands may not work."
    fi
}

# Function to update coverage
update_coverage() {
    print_info "Updating coverage data..."
    
    if command -v forge &> /dev/null; then
        print_info "Running Foundry coverage tests..."
        forge coverage --match-contract kpkShares --report lcov
        print_success "Coverage updated successfully"
    else
        print_error "Foundry not available. Cannot update coverage."
        exit 1
    fi
}

# Function to generate full report
generate_full_report() {
    print_info "Generating full coverage report..."
    
    if [[ ! -f "$LCOV_FILE" ]]; then
        print_error "LCOV file not found: $LCOV_FILE"
        print_info "Run '$0 update' first to generate coverage data"
        exit 1
    fi
    
    python3 "$(dirname "$0")/analyze_kpkShares_coverage.py" "$LCOV_FILE"
    print_success "Full report generated and saved to coverage_report.txt"
}

# Function to generate kpkShares report
generate_kpk_report() {
    print_info "Generating kpkShares focused coverage report..."
    
    if [[ ! -f "$LCOV_FILE" ]]; then
        print_error "LCOV file not found: $LCOV_FILE"
        print_info "Run '$0 update' first to generate coverage data"
        exit 1
    fi
    
    python3 "$(dirname "$0")/analyze_kpkShares_coverage.py" "$LCOV_FILE"
    print_success "kpkShares report generated and saved to kpkShares_coverage_report.txt"
}

# Function to show quick summary
show_summary() {
    print_info "Generating quick coverage summary..."
    
    if [[ ! -f "$LCOV_FILE" ]]; then
        print_error "LCOV file not found: $LCOV_FILE"
        print_info "Run '$0 update' first to generate coverage data"
        exit 1
    fi
    
    # Extract key metrics using grep and awk
    echo "Quick Coverage Summary:"
    echo "======================="
    
    # Count total files
    total_files=$(grep -c "^SF:" "$LCOV_FILE" || echo "0")
    echo "Total Files: $total_files"
    
    # Count kpkShares functions
    kpk_functions=$(grep -c "KpkShares\." "$LCOV_FILE" || echo "0")
    echo "kpkShares Functions: $kpk_functions"
    
    # Count covered kpkShares functions
    covered_kpk=$(grep "FNDA:" "$LCOV_FILE" | grep "KpkShares\." | awk -F',' '$1 > 0 {count++} END {print count+0}')
    echo "Covered kpkShares Functions: $covered_kpk"
    
    if [[ $kpk_functions -gt 0 ]]; then
        coverage_pct=$((covered_kpk * 100 / kpk_functions))
        echo "kpkShares Function Coverage: ${coverage_pct}%"
    fi
    
    echo ""
    echo "For detailed analysis, run:"
    echo "  $0 kpk     # Detailed kpkShares report"
    echo "  $0 full    # Full coverage report"
}

# Parse command line arguments
COMMAND=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--file)
            LCOV_FILE="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        full|kpk|summary|update)
            if [[ -n "$COMMAND" ]]; then
                print_error "Multiple commands specified. Use only one."
                exit 1
            fi
            COMMAND="$1"
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Check if command was specified
if [[ -z "$COMMAND" ]]; then
    print_error "No command specified"
    show_usage
    exit 1
fi

# Check dependencies
check_dependencies

# Execute command
case $COMMAND in
    update)
        update_coverage
        ;;
    full)
        generate_full_report
        ;;
    kpk)
        generate_kpk_report
        ;;
    summary)
        show_summary
        ;;
    *)
        print_error "Unknown command: $COMMAND"
        exit 1
        ;;
esac

print_success "Command completed successfully"
