'''
@author Matt Mulholland
@date 05/05/2015

Module of code that reads review data from raw text files and returns a list of files, describes the data, etc.
'''
import sys
import logging
logger = logging.getLogger()
import numpy as np
from re import sub
import pandas as pd
import seaborn as sns
from time import strftime
from langdetect import detect
import matplotlib.pyplot as plt
from os.path import abspath, basename, dirname, realpath, join
from langdetect.lang_detect_exception import LangDetectException


cdef read_reviews_from_game_file(file_path):
    '''
    Get list of reviews from a single game file.

    :param file_path: path to reviews file
    :type file_path: str
    :returns: list of dicts
    '''

    reviews = []
    lines = open(abspath(file_path)).readlines()
    cdef int i = 0
    while i + 1 < len(lines): # We need to get every 2-line couplet
        # Extract the hours value and the review text from each 2-line
        # sequence
        try:
            h = float(lines[i].split()[1].strip())
            r = lines[i + 1].split(' ', 1)[1].strip()
        except (ValueError, IndexError) as e:
            i += 2
            continue
        # Skip reviews that don't have any characters
        if not len(r):
            i += 2
            continue
        # Skip reviews if they cannot be recognized as English
        try:
            if not detect(r) == 'en':
                i += 2
                continue
        except LangDetectException:
            i += 2
            continue
        # Now we append the 2-key dict to the end of reviews
        reviews.append(dict(hours=h,
                            review=r))
        i += 2 # Increment i by 2 since we need to go to the next
            # 2-line couplet
    return reviews


def get_and_describe_dataset(file_path, report=True):
    '''
    Return dictionary with a list of filtered review dictionaries as well as the filtering values for maximum/minimum review length and minimum/maximum hours played values and the number of original, English-language reviews (before filtering); also produce a report with some descriptive statistics and graphs.

    :param file_path: path to game reviews file
    :type file_path: str
    :param report: make a report describing the data-set (defaults to True)
    :type report: boolean
    :returns: dict containing a 'reviews' key mapped to the list of read-in review dictionaries and int values mapped to keys for MAXLEN, MINLEN, MAXHOURS, and MINHOURS
    '''

    if report:

        # Get path to reports directory and open report file
        reports_dir = join(dirname(dirname(realpath(__file__))),
                           'reports')
        game = basename(file_path)[:-4]
        output_path = join(reports_dir,
                           '{}_report.txt'.format(game))
        output = open(output_path,
                      'w')

        # Initialize seaborn-related stuff
        sns.set_palette("deep",
                        desat=.6)
        sns.set_context(rc={"figure.figsize": (14, 7)})

    # Get list of review dictionaries
    reviews = read_reviews_from_game_file(file_path)

    if report:
        output.write('Descriptive Report for {}\n======================' \
                     '=================================================' \
                     '========\n\n'.format(sub(r'_',
                                               r' ',
                                               game)))
        output.write('Number of English-language reviews: {}\n' \
                     '\n'.format(len(reviews)))

    # Look at review lengths to figure out what should be filtered out
    lengths = np.array([len(review['review']) for review in reviews])
    cdef float meanl = lengths.mean()
    cdef float stdl = lengths.std()
    if report:
        output.write('Review Lengths Distribution\n\n')
        output.write('Average review length: {}\n'.format(meanl))
        output.write('Minimum review length = {}\n'.format(min(lengths)))
        output.write('Maximum review length = {}\n'.format(max(lengths)))
        output.write('Standard deviation = {}\n\n\n'.format(stdl))

    # Use the standard deviation to define the range of acceptable reviews
    # (in terms of the length only) as within 2 standard deviations of the
    # mean (but with the added caveat that the reviews be at least 50
    # characters
    cdef float minl = 50.0 if (meanl - 2*stdl) < 50 else (meanl - 2*stdl)
    cdef float maxl = meanl + 2*stdl

    if report:
        # Generate length histogram
        fig = plt.figure()
        ax = fig.add_subplot(111)
        ax.hist(pd.Series(lengths))
        ax.set_label(game)
        ax.set_xlabel('Review length (in characters)')
        ax.set_ylabel('Total reviews')
        fig.savefig(join(reports_dir,
                         '{}_length_histogram'.format(game)))
        plt.close(fig)

    # Look at hours played values in the same way as above for length
    hours = np.array([review['hours'] for review in reviews])
    cdef float meanh = hours.mean()
    cdef float stdh = hours.std()
    if report:
        output.write('Review Experience Distribution\n\n')
        output.write('Average game experience (in hours played): {}' \
                     '\n'.format(meanh))
        output.write('Minimum experience = {}\n'.format(min(hours)))
        output.write('Maximum experience = {}\n'.format(max(hours)))
        output.write('Standard deviation = {}\n\n\n'.format(stdh))

    # Use the standard deviation to define the range of acceptable reviews
    # (in terms of experience) as within 2 standard deviations of the mean
    # (starting from zero, actually)
    cdef float minh = 0.0
    cdef float maxh = meanh + 2*stdh

    # Write MAXLEN, MINLEN, etc. values to report
    if report:
        output.write('Filter Values\n' \
                     'Minimum length = {}\n' \
                     'Maximum length = {}\n' \
                     'Minimum hours played = {}\n' \
                     'Maximum hours played = {}\n'.format(minl,
                                                          maxl,
                                                          minh,
                                                          maxh))

    # Generate experience histogram
    if report:
        fig = plt.figure()
        ax = fig.add_subplot(111)
        ax.hist(pd.Series(hours))
        ax.set_label(game)
        ax.set_xlabel('Game experience (in hours played)')
        ax.set_ylabel('Total reviews')
        fig.savefig(join(reports_dir,
                         '{}_experience_histogram'.format(game)))
        plt.close(fig)

    if report:
        output.close()
    cdef int orig_total_reviews = len(reviews)
    reviews = [r for r in reviews if len(r['review']) <= maxl
                                     and len(r['review']) >= minl
                                     and r['hours'] <= maxh]
    return dict(reviews=reviews,
                minl=minl,
                maxl=maxl,
                minh=minh,
                maxh=maxh,
                orig_total_reviews=orig_total_reviews)


def get_bin_ranges(float _min, float _max, int nbins):
    '''
    Return list of floating point number ranges (in increments of 0.1) that correspond to each bin in the distribution.

    :param _min: minimum value of the distribution
    :type _min: float
    :param _max: maximum value of the distribution
    :type _max: float
    :param nbins: number of bins into which the distribution is being sub-divided
    :type nbins: int
    :returns: list of tuples representing the minimum and maximum values of each bin
    '''

    cdef float bin_size = round((_max - _min)/<float>nbins, 1)
    bin_ranges = []
    cdef float _bin_start = _min - 0.1
    cdef float _bin_end = _min + bin_size
    cdef int b
    for b in range(1, nbins + 1):
        if not b == 1:
            _bin_start = _bin_end
        if b == nbins:
            _bin_end = _bin_start + bin_size + 1.0
        else:
            _bin_end = _bin_start + bin_size
        bin_ranges.append((_bin_start,
                           _bin_end))
    return bin_ranges


def get_bin(bin_ranges, float val):
    '''
    Return the index of the bin range in which the value falls.

    :param bin_ranges: list of ranges that define each bin
    :type bin_ranges: list of tuples representing the minimum and maximum values of a range of values
    :param val: value
    :type val: float
    :returns: int (-1 if val not in any of the bin ranges)
    '''

    cdef int i
    for i, bin_range in enumerate(bin_ranges):
        if val > bin_range[0] and val <= bin_range[1]:
            return i + 1
    return -1


def write_arff_file(dest_path, file_names, reviews=None, reviewdb=None,
                    make_train_test=False, bins=False):
    '''
    Write .arff file either for a list of reviews read in from a file or list of files or for both the training and test partitions in the MongoDB database.

    :param reviews: list of dicts with hours/review keys-value mappings representing each data-point (defaults to None)
    :type reviews: list of dict
    :param reviewdb: MongoDB reviews collection
    :type reviewdb: pymongo.MongoClient object (None by default)
    :param dest_path: path for .arff output file
    :type dest_path: str
    :param file_names: list of extension-less game file-names
    :type file_names: list of str
    :param make_train_test: if True, use MongoDB collection to find reviews that are from the training and test partitions and make files for them instead of making one big file (defaults to False)
    :type make_train_test: boolean
    :param bins: if True or a list of bin range tuples, use collapsed hours played values (if make_train_test was also True, then the pre-computed collapsed hours values will be used (even if a list of ranges is passed in for some reason, i.e., the bin ranges will be ignored); if not, the passed-in value must be a list of 2-tuples representing the floating-point number ranges of the bins); if False, the original, unmodified hours played values will be used (default: False)
    :type bins: boolean or list of 2-tuples of floats
    :returns: None
    '''

    # Make sure that the passed-in keyword arguments make sense
    if make_train_test and (reviews or not reviewdb):
        logger.info('ERROR: The make_train_test keyword argument was set to' \
                    'True and either the reviewdb keyword was left ' \
                    'unspecified or the reviews keyword was specified (or ' \
                    'both). If the make_train_test keyword is used, it is ' \
                    'expected that training/test reviews will be retrieved ' \
                    'from the MongoDB database rather than a list of ' \
                    'reviews passed in via the reviews keyword. Exiting.')
        sys.exit(1)
    if not make_train_test and reviewdb:
        if reviews:
            logger.info('WARNING: Ignoring passed-in reviewdb keyword ' \
                        'value. Reason: If a list of reviews is passed in ' \
                         'via the reviews keyword argument, then the ' \
                         'reviewdb keyword argument should not be used at ' \
                         'all since it will not be needed.')
        else:
            logger.info('ERROR: A list of review dictionaries was not ' \
                        'specified. Exiting.')
            sys.exit(1)
    if bins:
        if make_train_test and type(bins) == list:
            logger.info('WARNING: The write_arff_file method was called ' \
                        'with \'make_train_test\' set to True and \'bins\' ' \
                        'set to a list of bin ranges ({}). Because the bin ' \
                        'values in the database were precomputed, the ' \
                        'passed-in list of bin ranges will be ignored' \
                        '.'.format(repr(bins)))
        if reviews and type(bins) == bool:
            logger.info('ERROR: The write_arff_file method was called with ' \
                        'a list of review dictionaries and \'bins\' set to ' \
                        'True. If the hours played values are to be ' \
                        'collapsed and precomputed values (as from the ' \
                        'database, for example) are not being used, then ' \
                        'the bin ranges must be specified. Exiting.')
            sys.exit(1)

    # ARFF file template
    ARFF_BASE = '''% Generated on {}
% This ARFF file was generated with review data from the following game(s): {}
% It is useful only for trying out machine learning algorithms on the bag-of-words representation of the reviews.
@relation reviewer_experience
@attribute string_attribute string
@attribute numeric_attribute numeric

@data'''
    TIMEF = '%A, %d. %B %Y %I:%M%p'

    # Replace underscores with spaces in game names and make
    # comma-separated list of games
    _file_names = str([sub(r'_',
                           r' ',
                           f) for f in file_names])

    # Write ARFF file(s)
    if make_train_test:

        # Make an ARFF file for each partition
        for partition in ['training', 'test']:

            # Make empty list of lines to populate with ARFF-style lines,
            # one per review
            reviews_lines = []

            # Get reviews for the given partition from all of the games
            game_docs = reviewdb.find({'partition': partition,
                                       'game': {'$in': file_names}})
            if game_docs.count() == 0:
                logger.info('ERROR: No matching documents were found in the' \
                            ' MongoDB collection for the {} partition and ' \
                            'the following games:\n\n{}'.format(partition,
                                                                file_names))
                logger.info('Exiting.')
                sys.exit(1)

            for game_doc in game_docs:
                # Remove single/double quotes from the reviews first...
                review = sub(r'\'|"',
                             r'',
                             game_doc['review'].lower())
                # Get rid of backslashes since they only make things
                # confusing
                review = sub(r'\\',
                             r'',
                             review)
                hours = game_doc['hours_bin'] if bins else game_doc['hours']
                reviews_lines.append('"{}",{}'.format(review,
                                                      hours))

            # Modify file-path by adding suffix(es)
            suffix = 'train' if partition.startswith('train') else 'test'
            replacement = suffix + '.arff'
            if bins:
                replacement = 'bins.' + replacement
            _dest_path = dest_path[:-4] + replacement

            # Write to file
            with open(_dest_path,
                      'w') as out:
                out.write('{}\n{}'.format(ARFF_BASE.format(strftime(TIMEF),
                                                           _file_names),
                                          '\n'.join(reviews_lines)))
    else:

        if not reviews:
            logger.info('ERROR: Empty list of reviews passed in to the ' \
                        'write_arff_file method. Exiting.')
            sys.exit(1)

        # Make empty list of lines to populate with ARFF-style lines,
        # one per review
        reviews_lines = []

        for rd in reviews:
            # Remove single/double quotes from the reviews first...
            review = sub(r'\'|"',
                         r'',
                         rd['review'].lower())
            # Get rid of backslashes since they only make things confusing
            review = sub(r'\\',
                         r'',
                         review)
            if bins:
                hours = get_bin(bins,
                                rd['hours'])
                if hours < 0:
                    logger.info('ERROR: The given hours played value ({}) ' \
                                'was not found in the list of possible bin ' \
                                'ranges ({}). Exiting.'.format(rd['hours'],
                                                               bins))
                    sys.exit(1)
            else:
                hours = rd['hours']
            reviews_lines.append('"{}",{}'.format(review,
                                                  hours))

        # Modify file-path by adding partition suffix
        if bins:
            dest_path = dest_path[:-4] + 'bins.arff'

        # Write to file
        with open(dest_path,
                  'w') as out:
            out.write('{}\n{}'.format(ARFF_BASE.format(strftime(TIMEF),
                                                       _file_names),
                                      '\n'.join(reviews_lines)))