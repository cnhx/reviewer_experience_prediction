"""
:author: Matt Mulholland
:date: 11/19/2015

Module of functions/classes related to learning experiments.
"""
import logging
from math import ceil
from bson import BSON
from os.path import join
from itertools import (chain,
                       repeat)

import numpy as np
import pandas as pd
from funcy import chunks
from nltk import FreqDist
from skll.metrics import kappa
from pymongo import (cursor,
                     ASCENDING,
                     collection)
from scipy.stats import pearsonr
from sklearn.cluster import MiniBatchKMeans
from sklearn.metrics import (f1_score,
                             accuracy_score,
                             precision_score,
                             confusion_matrix)
from sklearn.linear_model import PassiveAggressiveRegressor

from data import APPID_DICT
from src import (LABELS,
                 TIME_LABELS,
                 VALID_GAMES,
                 FRIENDS_LABELS,
                 HELPFUL_LABELS,
                 LEARNER_DICT_KEYS,
                 ACHIEVEMENTS_LABELS,
                 LEARNER_ABBRS_STRING,
                 LABELS_WITH_PCT_VALUES)
from src.datasets import (get_bin,
                          validate_bin_ranges,
                          compute_label_value)

# Logging-related
logger = logging.getLogger()
logerr = logger.error

NO_INTROSPECTION_LEARNERS = frozenset({MiniBatchKMeans,
                                       PassiveAggressiveRegressor})


def distributional_info(db: collection,
                        label: str,
                        games: list,
                        partition: str = 'all',
                        bin_ranges: list = None,
                        lognormal: bool = False,
                        power_transform: float = None,
                        limit: int = 0,
                        batch_size: int = 50) -> dict:
    """
    Generate some distributional information regarding the given label
    (or for the implicit/transformed labels given a list of label bin
    ranges and/or setting `lognormal` to True) for the for the given
    list of games.

    By default, no partition is specified ('all'), but either the
    'test' or 'train' partition can be specified via the `partition`
    parameter.

     A set of raw data transformations can be specified as well.
    `lognormal` can be set to True to transform raw values with the
    natural log and `power_transform` can be specified as a positive,
    non-zero float value to transform raw values such that
    `x**power_transform` is used.

    Also, a limit (concerning the cursor that is created) can be
    specified via the `limit` parameter.

    Returns a dictionary containing keys whose values are: a mapping
    between ID strings and label values and a frequency distribution of
    label values. If `bin_ranges` is specified, all labels will be
    converted using that information.

    :param db: MongoDB collection
    :type db: collection
    :param label: label used for prediction
    :type label: str
    :param games: list of game IDs
    :type games: list
    :param partition: data partition, i.e., 'train', 'test', or 'all'
                      to use all of the data (default: 'all')
    :type partition: str
    :param bin_ranges: list of ranges
    :type bin_ranges: list or None
    :param lognormal: transform raw label values using `ln` (default:
                      False)
    :type lognormal: bool
    :param power_transform: power by which to transform raw label
                            values (default: None)
    :type power_transform: float or None
    :param limit: cursor limit (defaults to 0, which signifies no
                                limit)
    :type limit: int

    :returns: dictionary containing `id_strings_labels_dict` and
              `labels_fdist` keys, which are mapped to a dictionary
              of ID strings mapped to labels and a `FreqDist` object
              representing the frequency distribution of the label
              values, respectively
    :rtype: dict
    :param batch_size: batch size to use for the returned cursor
    :type batch_size: int

    :raises ValueError: if unrecognized games were found in the input,
                        no reviews were found for the combination of
                        game, partition, etc., or `compute_label_value`
                        fails for some reason
    """

    # Validate parameter values
    if not partition in ['train', 'test', 'all']:
        raise ValueError('The only values recognized for the "partition" '
                         'parameter are "test", "train", and "all".')
    if not label in LABELS:
        raise ValueError('Unrecognized label: {0}'.format(label))
    if limit != 0 and (type(limit) != int or limit < 0):
        raise ValueError('"limit" must be a positive integer.')

    if any(not game in APPID_DICT for game in games):
        raise ValueError('All or some of the games in the given list of '
                         'games, {0}, are not in list of available games'
                         .format(', '.join(games)))

    if lognormal and power_transform:
        raise ValueError('Both "lognormal" and "power_transform" were '
                         'specified simultaneously.')

    if batch_size < 1:
        raise ValueError('"batch_size" must be greater than zero.')

    # Generate a query
    if len(games) == 1:
        query = {'game': games[0]}
    else:
        query = {'game': {'$in': games}}
    if partition != 'all':
        query['partition'] = partition

    # Create a MongoDB cursor on the collection
    kwargs = {'limit': limit}
    proj = {'nlp_features': 0}
    cursor = db.find(query, proj, **kwargs)
    cursor.batch_size = batch_size

    # Validate `bin_ranges`
    if bin_ranges:
        try:
            validate_bin_ranges(bin_ranges)
        except ValueError as e:
            logerr(e)
            raise ValueError('"bin_ranges" could not be validated.')

    # Get review documents (only including label + ID string)
    samples = []
    for doc in cursor:
        # Apply lognormal transformation and/or multiplication by 100
        # if this is a percentage value
        label_value = compute_label_value(get_label_in_doc(doc, label),
                                          label,
                                          lognormal=lognormal,
                                          power_transform=power_transform,
                                          bin_ranges=bin_ranges)

        # Skip label values that are equal to None
        if label_value == None:
            continue

        samples.append({'id_string': doc['id_string'], label: label_value})

    # Raise exception if no review documents were found
    if not samples:
        raise ValueError('No review documents were found!')

    # Return dictionary containing a key 'id_strings_labels_dict'
    # mapped to a dictionary mapping ID strings to label values and a
    # key 'labels_fdist' mapped to a `FreqDist` object of the label
    # values
    id_strings_labels_dict = {doc['id_string']: doc[label] for doc in samples}
    labels_fdist = FreqDist([doc[label] for doc in samples])
    return dict(id_strings_labels_dict=id_strings_labels_dict,
                labels_fdist=labels_fdist)


def get_label_in_doc(doc: dict, label: str):
    """
    Return the value for a label in a sample document and return None
    if not in the document.

    :param doc: sample document dictionary
    :type doc: dict
    :param label: document key that functions as a label
    :type label: str

    :returns: label value
    :rtype: int/float/str/None

    :raises ValueError: if the label is not in `LABELS`
    """

    if not label in LABELS:
        raise ValueError('Unrecognized label: {0}'.format(label))

    if label in doc:
        return doc[label]

    achievement_progress_string = 'achievement_progress'
    if achievement_progress_string in doc:
        achievement_progress = doc[achievement_progress_string]
        if label in achievement_progress:
            return achievement_progress[label]


def evenly_distribute_samples(db: collection,
                              label: str,
                              games: list,
                              partition: str = 'test',
                              bin_ranges: list = None,
                              lognormal: bool = False,
                              power_transform: float = None) -> str:
    """
    Generate ID strings from data samples that, altogether, form a
    maximally evenly-distributed set of samples with respect to the
    the prediction label or to the "binned" prediction label,
    specifically for cases when a small subset of the total data is
    being used. If `bin_ranges` is specified, all labels will be
    converted using it.

    By default, the 'test' partition is used, but the 'train' partition
    can be specified via the `partition` parameter. If 'all' is
    specified for the `partition` parameter, the partition is left
    unspecified (i.e., all of the data is used).

    :param db: MongoDB collection
    :type db: collection
    :param label: label used for prediction
    :type label: str
    :param games: list of game IDs
    :type games: list
    :param partition: data partition, i.e., 'train', 'test', or 'all'
                      to use all of the data (default: 'test')
    :type partition: str
    :param bin_ranges: list of ranges
    :type bin_ranges: list or None
    :param lognormal: transform raw label values using `ln` (default:
                      False)
    :type lognormal: bool
    :param power_transform: power by which to transform raw label
                            values (default: None)
    :type power_transform: float or None

    :yields: ID string
    :ytype: str

    :raises ValueError: if `bin_ranges` is invalid
    """

    # Check `partition` parameter value
    if partition != 'test' and not partition in ['train', 'all']:
        raise ValueError('The only values recognized for the "partition" '
                         'parameter are "test", "train", and "all" (for no '
                         'partition, i.e., all of the data).')

    # Validate transformer parameters
    if lognormal and power_transform:
        raise ValueError('Both "lognormal" and "power_transform" were '
                         'specified simultaneously.')

    # Get dictionary of ID strings mapped to labels and a frequency
    # distribution of the labels
    distribution_dict = distributional_info(db,
                                            label,
                                            games,
                                            partition=partition,
                                            bin_ranges=bin_ranges,
                                            lognormal=lognormal,
                                            power_transform=power_transform)

    # Create a maximally evenly-distributed list of samples with
    # respect to label
    labels_id_strings_lists_dict = dict()
    for label_value in distribution_dict['labels_fdist']:
        labels_id_strings_lists_dict[label_value] = \
            [_id for _id, _label
             in distribution_dict['id_strings_labels_dict'].items()
             if _label == label_value]
    i = 0
    while i < len(distribution_dict['id_strings_labels_dict']):

        # For each label value, pop off an ID string, if available
        for label_value in distribution_dict['labels_fdist']:
            if labels_id_strings_lists_dict[label_value]:
                yield labels_id_strings_lists_dict[label_value].pop()
                i += 1


def get_all_features(review_doc: dict, prediction_label: str,
                     nlp_features: bool = True) -> dict:
    """
    Get all the features in a review document and put them together in
    a dictionary. If `nlp_features` is False, leave out NLP features.

    :param review_doc: review document from Mongo database
    :type review_doc: dict
    :param prediction_label: label being used for prediction
    :type prediction_label: str
    :param nlp_features: extract NLP features (default: True)
    :type nlp_features: bool

    :returns: feature dictionary
    :rtype: dict or None
    """

    _get = review_doc.get
    features = {}
    _update = features.update
    nan = float("NaN")

    # Add in the NLP features
    if nlp_features:
        _update({feat: val for feat, val
                 in BSON.decode(_get('nlp_features')).items()
                 if val and val != nan})

    # Add in the non-NLP features (except for those that may be in
    # the 'achievement_progress' sub-dictionary of the review
    # dictionary)
    _update({feat: val for feat, val in review_doc.items()
             if feat in set(LABELS) and val and val != nan})

    # Add in the features that may be in the 'achievement_progress'
    # sub-dictionary of the review document
    _update({feat: val for feat, val
             in _get('achievement_progress', dict()).items()
             if feat in set(LABELS) and val and val != nan})

    # Return None if the prediction label isn't present
    if not features.get(prediction_label):
        return

    # Add in the 'id_string' value just to make it easier to
    # process the results of this function
    _update({'id_string': _get('id_string')})
    return features


def get_data_point(review_doc: dict,
                   prediction_label: str,
                   nlp_features: bool = True,
                   non_nlp_features: list = [],
                   lognormal: bool = False,
                   power_transform: float = None,
                   bin_ranges: list = None) -> dict:
    """
    Collect data from a MongoDB review document and return it in format
    needed for `DictVectorizer`.

    :param review_doc: document from the MongoDB reviews collection
    :type review_doc: dict
    :param prediction_label: label being used for prediction
    :type prediction_label: str
    :param nlp_features: extract NLP features (default: True)
    :type nlp_features: bool
    :param non_nlp_features: list of non-NLP features to extract
    :type non_nlp_features: list
    :param lognormal: transform raw label values using `ln` (default:
                      False)
    :type lognormal: bool
    :param power_transform: power by which to transform raw label
                            values (default: None)
    :type power_transform: float or None
    :param bin_ranges: list of ranges that define each bin, where each
                       bin should be represented as a tuple with the
                       first value, a float that is precise to one
                       decimal place, as the lower bound and the
                       second, also a float with the same type of
                       precision, the upper bound, but both limits are
                       technically soft since label values will be
                       compared to see if they are equal at the same
                       precision and so they can end up being
                       larger/smaller and still be in a given bin;
                       the bins should also make up a continuous range
                       such that every first bin value should be
                       less than the second bin value and every bin's
                       values should be less than the succeeding bin's
                       values
    :type bin_ranges: list of tuples representing the minimum and
                      maximum values of a range of values (or None)

    :returns: training/test sample
    :rtype: dict or None
    """

    # Get dictionary containing all features needed + the ID and the
    # prediction label
    feature_dict = get_all_features(review_doc, prediction_label,
                                    nlp_features=nlp_features)

    # Return if the feature dictionary is empty (i.e., due to the
    # absence of the prediction label, or if for some reason the
    # dictionary is otherwise empty)
    if not feature_dict:
        return

    # Get prediction label, apply transformations, and remove it from
    # the feature dictionary
    y_value = compute_label_value(feature_dict[prediction_label],
                                  prediction_label,
                                  lognormal=lognormal,
                                  power_transform=power_transform,
                                  bin_ranges=bin_ranges)
    del feature_dict[prediction_label]

    # Get ID and remove from feature dictionary
    _id_string = 'id_string'
    id_string = feature_dict[_id_string]
    del feature_dict[_id_string]

    # Only keep the non-NLP features that are supposed to be kept, if
    # any
    for feat in LABELS:
        if not feat in non_nlp_features and feature_dict.get(feat, None) != None:
            del feature_dict[feat]

    # If, after taking out the prediction label and the ID, there are
    # no remaining features, return None
    if not feature_dict:
        return

    # Return dictionary of prediction label value, ID string, and
    # features
    return {'y': y_value, 'id': id_string, 'x': feature_dict}


def fit_preds_in_scale(y_preds: np.array, classes: np.array) -> np.array:
    """
    Force values at either end of the scale to fit within the scale by
    adding to or truncating the values.

    :param y_preds: array of predicted labels
    :type y_preds: np.array
    :param classes: array of class labels
    :type clases: np.array

    :returns: array of predicted labels
    :rtype: np.array
    """

    # Get low/high ends of the scale
    scale = sorted(classes)
    low = scale[0]
    high = scale[-1]

    cdef int i = 0
    while i < len(y_preds):
        if y_preds[i] < low:
            y_preds[i] = low
        elif y_preds[i] > high:
            y_preds[i] = high
        i += 1

    return y_preds


def make_printable_confusion_matrix(y_test: np.array, y_preds: np.array,
                                    classes: np.array) -> tuple:
    """
    Produce a printable confusion matrix to use in the evaluation
    report (and also return the confusion matrix multi-dimensional
    array).

    :param y_test: array of actual labels
    :type y_test: np.array
    :param y_preds: array of predicted labels
    :type y_preds: np.array
    :param classes: array of class labels
    :type clases: np.array

    :returns: tuple consisting of a confusion matrix string and a
              confusion matrix multi-dimensional array
    :rtype: tuple
    """

    cnfmat = confusion_matrix(y_test, np.round(y_preds), labels=classes).tolist()
    header = ('confusion_matrix (rounded predictions) (row=actual, '
              'col=machine, labels={0}):\n'.format(classes))
    tab_join = '\t'.join
    row_format = '{0}{1}\n'.format
    labels_list = [''] + [str(cls) for cls in classes]
    res = row_format(header, tab_join(labels_list))
    for row, label in zip(cnfmat, classes):
        row = tab_join([str(x) for x in [label] + row])
        res = row_format(res, row)

    return res, cnfmat


def get_sorted_features_for_learner(learner, classes: np.array,
                                    vectorizer) -> list:
    """
    Get the best-performing features in a model (excluding
    `MiniBatchKMeans` and `PassiveAggressiveRegressor` learners and
    `FeatureHasher`-vectorized models).

    :param learner: learner (can not be of type `MiniBatchKMeans` or
                    `PassiveAggressiveRegressor`, among others)
    :type learner: learner instance
    :param classes: array of class labels
    :type clases: np.array
    :param vectorizer: vectorizer object
    :type vectorizer: DictVectorizer or FeatureHasher vectorizer

    :returns: list of sorted features (in dictionaries)
    :rtype: list

    :raises ValueError: if the given learner is not of the type of one
                        of the supported learner types or features
                        cannot be extracted for some other reason
    """

    # Raise exception if learner class is not supported
    if any(issubclass(type(learner), cls) for cls in NO_INTROSPECTION_LEARNERS):
        raise ValueError('Can not get feature weights for learners of type '
                         '{0}'.format(type(learner)))

    # Store feature coefficient tuples
    feature_coefs = []

    # Get tuples of feature + label/coefficient tuples, one for each
    # label
    for index, feat in enumerate(vectorizer.get_feature_names()):

        # Get list of coefficient arrays for the different classes
        try:
            coef_indices = [learner.coef_[i][index] for i, _ in enumerate(classes)]
        except IndexError:
            raise ValueError('Could not get feature coefficients!')

        # Append feature coefficient tuple to list of tuples
        feature_coefs.append(tuple(list(chain([feat],
                                              zip(classes, coef_indices)))))

    # Unpack tuples of features and label/coefficient tuples into one
    # long list of feature/label/coefficient values, sort, and filter
    # out any tuples with zero weight
    features = []
    _extend = features.extend
    for i in range(1, len(classes) + 1):
        _extend([dict(feature=coefs[0], label=coefs[i][0], weight=coefs[i][1])
                 for coefs in feature_coefs if coefs[i][1]])

    return sorted(features, key=lambda x: abs(x['weight']), reverse=True)


def print_model_weights(learner,
                        learner_name: str,
                        classes: np.array,
                        games: set,
                        vectorizer,
                        output_path: str) -> None:
    """
    Print a sorted list of model weights for a given learner model to
    an output file.

    :param learner: learner (can not be of type `MiniBatchKMeans` or
                    `PassiveAggressiveRegressor`, among others)
    :type learner: learner instance
    :param learner_name: name associated with learner
    :type learner_name: str
    :param games: set of games (str)
    :type games: set
    :param classes: array of class labels
    :type clases: np.array
    :param vectorizer: vectorizer object
    :type vectorizer: DictVectorizer or FeatureHasher vectorizer
    :param output_path: path to output file
    :type output_path: str

    :returns: None
    :rtype: None

    :raises ValueError: if the call to
                        `get_sorted_features_for_learner` fails or the
                        features cannot be extracted for some other
                        reason
    """

    # Get dataframe of the features/coefficients
    sorted_features = get_sorted_features_for_learner(learner, classes,
                                                      vectorizer)
    if sorted_features:

        # Generate feature weights report
        pd.DataFrame(sorted_features).to_csv(output_path, index=False)

    else:
        raise ValueError('Could not generate features/feature coefficients '
                         'dataframe for {0}...'.format(learner_name))


def make_cursor(db: collection,
                partition: str = '',
                projection: dict = {},
                games: list = [],
                sorting_args: list = [('steam_id_number', ASCENDING)],
                batch_size: int = 50,
                id_strings: list = []) -> cursor:
    """
    Make cursor (for a specific set of games and/or a specific
    partition of the data, if specified) or for for data whose
    `id_string` values are within a given set of input values.

    :param db: MongoDB collection
    :type db: collection
    :param partition: partition of MongoDB collection
    :type partition: str
    :param projection: projection for filtering out certain values from
                       the returned documents
    :type projection: dict
    :param games: set of games (str)
    :type games: set
    :param sorting_args: argument to use in the MongoDB collection's
                         `sort` method (to not do any sorting, pass an
                         empty list)
    :type sorting_args: list
    :param batch_size: batch size to use for the returned cursor
    :type batch_size: int
    :param id_strings: list of ID strings (pass an empty list if not
                       constraining the cursor to documents with a set
                       of specific `id_string` values)
    :type id_strings: list

    :returns: cursor on a MongoDB collection
    :rtype: cursor

    :raises ValueError: if `games` contains unrecognized games,
                        `batch_size` is less than 1, `partition` is an
                        unrecognized value, or `id_strings` was
                        specified simultaneously with `partition`
                        and/or `games`
    """

    # Validate parameters
    if id_strings and (partition or games):
        raise ValueError('Cannot specify both a set of ID strings and a '
                         'partition and/or a set of games simultaneously.')

    # Validate `games`
    if any(not game in APPID_DICT for game in games):
        raise ValueError('"games" contains invalid games: {0}.'.format(games))

    # Validate `batch_size`
    if batch_size < 1:
        raise ValueError('"batch_size" must be greater than zero: {0}'
                         .format(batch_size))

    # Validate `partition`
    if partition and not partition in ['training', 'test']:
        raise ValueError('"partition" is invalid (must be "training" or '
                         '"test", if specified): {0}'.format(partition))

    # Make training data cursor
    query = {}
    if partition:
        query['partition'] = partition
    if len(games) == 1:
        query['game'] = games[0]
    elif games:
        query['game'] = {'$in': games}
    if id_strings:
        query['id_string'] = {'$in': id_strings}
    _cursor = db.find(query, projection, timeout=False)
    _cursor.batch_size = batch_size
    if sorting_args:
        _cursor = _cursor.sort(sorting_args)

    return _cursor


def compute_evaluation_metrics(y_test: np.array, y_preds: np.array,
                               classes: np.array) -> dict:
    """
    Compute evaluation metrics given actual and predicted label values
    and the set of possible label values.

    :param y_test: array of actual labels
    :type y_test: np.array
    :param y_preds: array of predicted labels
    :type y_preds: np.array
    :param classes: array of class labels
    :type clases: np.array

    :returns: statistics dictionary
    :rtype: dict
    """

    # Get Pearson r and significance
    r, sig = pearsonr(y_test, y_preds)

    # Get confusion matrix (both the np.ndarray and the printable
    # one)
    printable_cnfmat, cnfmat = make_printable_confusion_matrix(y_test,
                                                               y_preds,
                                                               classes)

    return {'pearson_r': r,
            'significance': sig,
            'precision_macro': precision_score(y_test,
                                               y_preds,
                                               labels=classes,
                                               average='macro'),
            'precision_weighted': precision_score(y_test,
                                                  y_preds,
                                                  labels=classes,
                                                  average='weighted'),
            'f1_macro': f1_score(y_test,
                                 y_preds,
                                 labels=classes,
                                 average='macro'),
            'f1_weighted': f1_score(y_test,
                                    y_preds,
                                    labels=classes,
                                    average='weighted'),
            'accuracy': accuracy_score(y_test,
                                       y_preds,
                                       normalize=True),
            'confusion_matrix': cnfmat,
            'printable_confusion_matrix': printable_cnfmat,
            'uwk': kappa(y_test, y_preds),
            'uwk_off_by_one': kappa(y_test,
                                    y_preds,
                                    allow_off_by_one=True),
            'qwk': kappa(y_test,
                             y_preds,
                             weights='quadratic'),
            'qwk_off_by_one': kappa(y_test,
                                    y_preds,
                                    weights='quadratic',
                                    allow_off_by_one=True),
            'lwk': kappa(y_test,
                         y_preds,
                         weights='linear'),
            'lwk_off_by_one': kappa(y_test,
                                    y_preds,
                                    weights='linear',
                                    allow_off_by_one=True)}


def evaluate_predictions_from_learning_round(y_test: np.array,
                                             y_test_preds: np.array,
                                             classes: np.array,
                                             prediction_label: str,
                                             non_nlp_features: list,
                                             nlp_features: bool,
                                             learner,
                                             learner_name: str,
                                             games: set,
                                             test_games: set,
                                             _round: int,
                                             n_train_samples: int,
                                             bin_ranges: list,
                                             transformation_string: str) -> pd.Series:
    """
    Evaluate predictions made by a learner during a round of learning
    (e.g., in `src.learn.RunExperiments` and return a Series of metrics
    and other data.

    :param y_test: actual values
    :type y_test: np.array
    :param y_test_preds: predicted values
    :type y_test_preds: np.array
    :param classes: array of possible values
    :type classes: np.array
    :param prediction_label: label being used for prediction
    :type prediction_label: str
    :param non_nlp_features: list of non-NLP features being used
    :type non_nlp_features: list
    :param nlp_features: whether or not NLP features are being used
    :type nlp_features: bool
    :param learner: learner instance
    :type learner: learner type
    :param learner_name: name of learner type
    :type learner_name: str
    :param games: set of training games
    :type games: set
    :param test_games: set of test games
    :type test_games: set
    :param _round: index of round of learning
    :type _round: int
    :param n_train_samples: number of samples used for training
    :type n_train_samples: int
    :param bin_ranges: list of ranges that define each bin, where each
                       bin should be represented as a tuple with the
                       first value, a float that is precise to one
                       decimal place, as the lower bound and the
                       second, also a float with the same type of
                       precision, the upper bound, but both limits are
                       technically soft since label values will be
                       compared to see if they are equal at the same
                       precision and so they can end up being
                       larger/smaller and still be in a given bin;
                       the bins should also make up a continuous range
                       such that every first bin value should be
                       less than the second bin value and every bin's
                       values should be less than the succeeding bin's
                       values
    :type bin_ranges: list of tuples representing the minimum and
                      maximum values of a range of values (or None)
    :param transformation_string: string representation of transformation
    :type transformation_string: str

    :returns: a pandas Series of evaluation metrics and other data
              collected during the learning round
    :rtype: pd.Series
    """

    # Evaluate the new model, collecting metrics, etc., and then
    # store the round's metrics
    stats_dict = compute_evaluation_metrics(y_test, y_test_preds, classes)
    stats_dict.update({'games' if len(games) > 1 else 'game':
                           ', '.join(games) if VALID_GAMES.difference(games)
                           else 'all_games',
                       'test_games' if len(test_games) > 1 else 'test_game':
                           ', '.join(test_games)
                           if VALID_GAMES.difference(test_games)
                           else 'all_games',
                       'learning_round': int(_round),
                       'prediction_label': prediction_label,
                       'test_set_labels/test_set_predictions':
                           list(zip(y_test, y_test_preds)),
                       'learner': learner_name,
                       'params': learner.get_params(),
                       'training_samples': n_train_samples,
                       'non-NLP features': ', '.join(non_nlp_features),
                       'NLP features': nlp_features,
                       'transformation': transformation_string})
    if bin_ranges:
        stats_dict.update({'bin_ranges': bin_ranges})

    return pd.Series(stats_dict)


class ExperimentalData(object):
    """
    Class for objects storing training and grid search datasets,
    organized into folds, and a test set dataset. Each dataset contains
    an array or list of arrays of sample IDs corresponding to data
    samples in a collection.
    """

    num_datasets = None
    training_set = None
    test_set = np.array([])
    grid_search_set = None
    sampling = None
    prediction_label = None
    games = None
    test_games = None
    folds = None
    fold_size = None
    grid_search_folds = None
    grid_search_fold_size = None
    bin_ranges = None
    test_bin_ranges = None
    lognormal = None
    power_transform = None
    labels_fdist = None
    id_strings_labels = None

    sampling_options = frozenset({'even', 'stratified'})

    def __init__(self,
                 db: collection,
                 prediction_label: str,
                 games: set,
                 folds: int,
                 fold_size: int,
                 grid_search_folds: int,
                 grid_search_fold_size: int,
                 test_games: set = None,
                 test_size: int = 0,
                 sampling: str = 'stratified',
                 bin_ranges: list = None,
                 test_bin_ranges: list = None,
                 lognormal: bool = False,
                 power_transform: float = None,
                 batch_size: int = 50):
        """
        Initialize an `ExperimentalData` object.

        :param db: MongoDB collection
        :type db: collection
        :param prediction_label: label to use for prediction
        :type prediction_label: str
        :param games: set of games (str)
        :type games: set
        :param folds: number of folds with which to split the data
        :type folds: int
        :param fold_size: maximum number of data samples to use for
                          each fold of the main data folds (the actual
                          number of samples in any given fold may be
                          less than this number)
        :type fold_size: int
        :param grid_search_folds: number of folds set aside for grid
                                  search
        :type grid_search_folds: int
        :param grid_search_fold_size: maximum number of data samples to
                                      use for each fold of the grid
                                      search fold set (the actual number
                                      of samples in any given fold may
                                      be less than this number)
        :type grid_search_fold_size: int
        :param test_games: set of games (str) to use for testing (use
                           same value as for `games` or leave
                           unspecified, which will default to the games
                           used for `games`)
        :type test_games: set or None
        :param test_size: maximum for the number of samples to include
                          in a test data partition separate from the
                          rest of the data-sets (defaults to 0,
                          signifying that no separate test set will be
                          generated) (the actual number of samples may
                          be less than this number, depending on the
                          number of samples for each label, etc.)
        :type test_size: int
        :param sampling: how each dataset partition (whether it be in
                         the grid search folds, the main datasets, or
                         the test set) is distributed in terms of the
                         labels, which can be either of two choices:
                         'even', which tries to make the internal
                         distribution as even as possible or
                         'stratified' (the default value), which tries
                         to retain the frequency distribution of the
                         dataset as a whole within each partition of the
                         data
        :type sampling: str
        :param bin_ranges: list of ranges that define each bin, where
                           each bin should be represented as a tuple
                           with the first value, a float that is
                           precise to one decimal place, as the lower
                           bound and the second, also a float with the
                           same type of precision, the upper bound, but
                           both limits are technically soft since label
                           values will be compared to see if they are
                           equal at the same precision and so they can
                           end up being larger/smaller and still be in
                           a given bin; the bins should also make up a
                           continuous range such that every first bin
                           value should be less than the second bin
                           value and every bin's values should be less
                           than the succeeding bin's values
        :type bin_ranges: list of tuples representing the minimum and
                          maximum values of a range of values (or None)
        :param test_bin_ranges: see description above for `bin-ranges`
        :type test_bin_ranges: list of tuples
        :param lognormal: transform raw label values using `ln`
                          (default: False)
        :type lognormal: bool
        :param power_transform: power by which to transform raw label
                                values (default: None)
        :type power_transform: float or None
        :param batch_size: batch size to use for the database cursor
        :type batch_size: int (default: 50)

        :raises ValueError: if `games`/`test_games` contains
                            unrecognized games, etc.
        """

        # Validate parameters
        self.games = games
        if not games:
            raise ValueError('"games" must be a non-empty set.')

        # If `test_games` is left unspecified or is an empty set, treat
        # it as if equal to `games`
        self.test_games = test_games if test_games else self.games
        for game in set(chain(self.games, self.test_games)):
            if not game in APPID_DICT:
                raise ValueError('Unrecognized game: {0}.'.format(game))

        if batch_size < 1:
            raise ValueError('"batch_size" must have a positive, non-zero '
                             'value.')
        for parameter in ['folds', 'fold_size', 'grid_search_folds',
                          'grid_search_fold_size', 'test_size']:
            if eval(parameter) < 0:
                raise ValueError('"{}" must be non-negative: {0}'
                                 .format(eval(parameter)))

        # `test_size` should be specified if `games`/`test_games`
        # differ, as should `test_bin_ranges` if `bin_ranges` is also
        # specified
        self._games_test_games_equal = self.test_games == self.games
        if not self._games_test_games_equal:
            if test_size < 0:
                raise ValueError('"test_size" should be specified as a value '
                                 'greater than 0 when "games" differs from '
                                 '"test_games" (i.e., when a test set needs to '
                                 'be constructed).')

            if bin_ranges:
                if not test_bin_ranges:
                    raise ValueError('If "bin_ranges" for the training games '
                                     'is specified, then "test_bin_ranges" '
                                     'must also be specified.')
                if len(bin_ranges) != len(test_bin_ranges):
                    raise ValueError('If both "bin_ranges" and '
                                     '"test_bin_ranges" are specified, then '
                                     'they must agree in terms of implicit '
                                     'labels, i.e., length or number of bins.')
            else:
                if test_bin_ranges:
                    raise ValueError('If "test_bin_ranges" is specified, '
                                     '"bin_ranges" must also be specified.')

        # Validate the `sampling` parameter value
        if not sampling in self.sampling_options:
            raise ValueError('The "sampling" parameter must be either "even" '
                             'or "stratified". "{}" was given instead.'
                             .format(sampling))

        self.db = db
        self.prediction_label = prediction_label
        self.folds = folds
        self.fold_size = fold_size
        self.grid_search_folds = grid_search_folds
        self.grid_search_fold_size = grid_search_fold_size
        self.sampling = sampling
        self.distributional_info_kwargs = {'power_transform': power_transform,
                                           'lognormal': lognormal,
                                           'bin_ranges': bin_ranges,
                                           'batch_size': batch_size}
        self.test_bin_ranges = test_bin_ranges if test_bin_ranges else bin_ranges
        self.test_size = test_size

        # Construct the dataset
        self._construct_layered_dataset()

    def _make_test_set(self) -> np.array:
        """
        Generate a list of `id_string`s for the test set.

        :returns: None
        :rtype: None
        """

        # Make a dictionary mapping each label value to a list of sample
        # IDs
        distribution_data = distributional_info(self.db,
                                                self.prediction_label,
                                                list(self.test_games),
                                                **self.distributional_info_kwargs)
        id_strings_labels_test = distribution_data['id_strings_labels_dict']
        labels_fdist_test = distribution_data['labels_fdist']

        # If `self.games` and `self.test_games` are equivalent, cache
        # the values for `id_strings_labels_test` and
        # `labels_fdist_test` as `self.id_strings_labels` and
        # `self.labels_fdist`, respectively
        if self._games_test_games_equal:
            self.id_strings_labels = id_strings_labels_test
            self.labels_fdist = labels_fdist_test

        # Return if there are no samples from which to generate a test
        # set (which should not be the case)
        if not id_strings_labels_test:
            return

        # Test data IDs
        prng = np.random.RandomState(12345)
        test_set = []
        _extend = test_set.extend

        if self.sampling == 'stratified':

            # Iterate over the labels to figure out whether or not the
            # desired size of the test set needs to be adjusted and, if
            # so, by what factor
            factor = 1.0

            # Also, cache the sets of samples for each label
            labels_ids = {}
            for label in sorted(labels_fdist_test,
                                key=lambda _label: labels_fdist_test[_label]):
                all_label_ids = np.array([_id for _id in id_strings_labels_test
                                          if id_strings_labels_test[_id] == label])
                all_label_ids.sort()
                prng.shuffle(all_label_ids)
                labels_ids[label] = all_label_ids
                label_freq = labels_fdist_test.freq(label)
                n_label_test_data = int(np.ceil(label_freq*self.test_size))
                n_label_test_data_actual = len(all_label_ids[:n_label_test_data])
                if n_label_test_data_actual < n_label_test_data:
                    new_factor = \
                        (1.0 - ((n_label_test_data - n_label_test_data_actual)
                                /n_label_test_data))
                    if new_factor < factor:
                        factor = new_factor

            # Iterate over the lists of label sample lists and add the
            # samples to the test data set (refactoring the size of the
            # test set if needed -- unless the refactoring requires a
            # reduction in size of greater than 50%)
            if factor < 1.0:
                if (1.0 - factor) < 0.5:
                    raise ValueError('Could not generate a stratified test set'
                                     ' that is equal to the desired size or '
                                     'even 50% of the desired size.')
                self.test_size = factor*self.test_size
            for label in labels_ids:
                all_label_ids = labels_ids[label]
                label_freq = labels_fdist_test.freq(label)
                n_label_test_data = int(np.ceil(label_freq*self.test_size))
                _extend(all_label_ids[:n_label_test_data])

        else:

            # Store the length of the smallest label set (for ensuring
            # an even distribution, even it means a smaller test set
            # size)
            n_label_min = None
            for label in sorted(labels_fdist_test,
                                key=lambda _label: labels_fdist_test[_label]):
                all_label_ids = np.array([_id for _id in id_strings_labels_test
                                          if id_strings_labels_test[_id] == label])
                all_label_ids.sort()
                prng.shuffle(all_label_ids)
                n_label_test_data = int(np.ceil(self.test_size/len(labels_fdist_test)))
                n_label_test_data_actual = len(all_label_ids[:n_label_test_data])
                if not n_label_min:

                    # Check if `n_label_test_data_actual` is 0
                    # This kind of case should not occur, but, if it
                    # does, then it's a big problem
                    if not n_label_test_data_actual:
                        raise ValueError('The total number of samples for '
                                         'label {0} in the test set is 0.'
                                         .format(label))
                    n_label_min = n_label_test_data_actual

                _extend(all_label_ids[:n_label_min])

        # Convert the list of sample IDs into an array, shuffle it and
        # then ensure that its size is no larger than `self.test_size`
        test_set = np.array(test_set)
        test_set.sort()
        prng.shuffle(test_set)
        if len(test_set) > self.test_size:
            test_set = test_set[:self.test_size]

        return test_set

    def _generate_labels_dict(self) -> dict:
        """
        Generate a dictionary of labels mapped to lists of
        ID strings.

        :returns: dictionary of labels mapped to arrays of ID strings
        :rtype: dict
        """

        prng = np.random.RandomState(12345)
        labels_id_strings = {}
        for label in self.labels:
            all_ids = np.array([_id for _id in self.id_strings_labels
                                if self.id_strings_labels[_id] == label])
            all_ids.sort()
            prng.shuffle(all_ids)
            labels_id_strings[label] = all_ids

        return labels_id_strings

    def _generate_training_fold(self, _fold_size: int,
                                n_folds_collected: int,
                                n_folds_needed: int) -> np.array:
        """
        Generate a fold for use in the training/grid search data-set.

        :param _fold_size: size of fold
        :type _fold_size: int
        :param n_folds_collected: number of folds already generated for
                                  this data-set
        :type n_folds_collected: int
        :param n_folds_needed: number of folds that need to be generated
                               for this data-set
        :type n_folds_needed: int

        :returns: a balanced array comprising a fold (sampling will be
                  done according to `self.sampling`)
        :rtype: list
        """

        # Fold set sample IDs
        prng = np.random.RandomState(12345)
        fold_set = []
        _extend = fold_set.extend

        if self.sampling == 'stratified':

            # Iterate over the labels to figure out whether or not the
            # desired size of the fold set needs to be adjusted and, if
            # so, by what factor
            factor = 1.0

            # Also, cache the sets of samples for each label
            labels_ids = {}
            for label in sorted(self.labels_fdist,
                                key=lambda _label: self.labels_fdist[_label]):
                all_label_ids = np.array([_id for _id in self.id_strings_labels
                                          if self.id_strings_labels[_id] == label])
                all_label_ids.sort()
                prng.shuffle(all_label_ids)
                labels_ids[label] = all_label_ids
                label_freq = self.labels_fdist.freq(label)
                n_label_data = int(np.ceil(label_freq*_fold_size))
                n_label_data_actual = len(all_label_ids[:n_label_data])
                if n_label_data_actual < n_label_data:
                    new_factor = \
                        (1.0 - ((n_label_data - n_label_data_actual)
                                /n_label_data))
                    if new_factor < factor:
                        factor = new_factor

            # Iterate over the lists of label sample lists and add the
            # samples to the test data set (refactoring the size of the
            # test set if needed and if the resizing leads to a
            # reduction in the size that is greater than 10%, raise an
            # exception if this is the first (and not the only needed)
            # fold of the data (since that would mean that the data-set
            # will contain a fold that has an irregular distribution of
            # labels and that no more folds will be able to be generated
            # since the data will be exhausted) or simply return an
            # empty fold)
            if factor < 1.0:
                if n_folds_needed != 1 and (1.0 - factor) < 0.1:
                    if len(n_folds_collected):
                        raise ValueError('Generating an extra fold will result'
                                         ' in a reduced size (greater than 10%'
                                         ' reduction) for a given label.')
                    else:
                        return np.array([])
                _fold_size = factor*_fold_size
            for label in labels_ids:
                all_label_ids = labels_ids[label]
                label_freq = self.labels_fdist.freq(label)
                n_label_data = int(np.ceil(label_freq*_fold_size))
                _extend(all_label_ids[:n_label_data])

        else:

            # Store the length of the smallest label set (for ensuring
            # an even distribution, even it means a smaller fold set
            # size)
            n_label_min = None
            for label in sorted(self.labels_fdist,
                                key=lambda _label: self.labels_fdist[_label]):
                all_label_ids = np.array([_id for _id in self.id_strings_labels
                                          if self.id_strings_labels[_id] == label])
                all_label_ids.sort()
                prng.shuffle(all_label_ids)
                n_label_data = int(np.ceil(_fold_size/len(self.labels_fdist)))
                n_label_data_actual = len(all_label_ids[:n_label_data])
                if not n_label_min:

                    # Check if `n_label_data_actual` is 0
                    # This kind of case should not occur, but, if it
                    # does, it's a problem that either requires raising
                    # an exception or returning an empty fold -- if the
                    # number of folds that have already been generated
                    # for this data-set is greater than 0, then it just
                    # means that other folds cannot be generated
                    if not n_label_data_actual:
                        if not n_folds_collected:
                            raise ValueError('Could not generate fold due to a'
                                             ' lack of samples.')
                        return np.array([])
                    n_label_min = n_label_data_actual

                _extend(all_label_ids[:n_label_min])

        # Convert the list of sample IDs into an array, shuffle it and
        # then ensure that its size is no larger than `_fold_size`
        fold_set = np.array(fold_set)
        fold_set.sort()
        prng.shuffle(fold_set)
        if len(fold_set) > _fold_size:
            fold_set = fold_set[:_fold_size]

        # Remove used-up samples from `self.id_strings_labels`
        for _id in fold_set:
            del self.id_strings_labels[_id]

        return fold_set

    def _generate_dataset(self, grid_search: bool = False) -> np.array:
        """
        Generate partitioned dataset for training rounds (or for the
        grid search rounds, if `grid_search` is True).

        :param grid_search: whether or not the dataset being generated
                            is for the grid search set or not (if not,
                            the main training set will be generated)
                            (defaults to False)
        :type grid_search: bool

        :returns: dictionary mapping index numbers corresponding to
                  dataset folds to arrays containing ID strings
        :rtype: np.array
        """

        training_set = []
        folds_collected = 0
        if grid_search:
            folds = eval('self.grid_search_folds')
            fold_size = eval('self.grid_search_fold_size')
        else:
            folds = eval('self.folds')
            fold_size = eval('self.fold_size')
        for _ in range(folds):
            fold_set = self._generate_training_fold(fold_size,
                                                    folds_collected,
                                                    folds)
            if len(fold_set):
                training_set.append(fold_set)
                folds_collected += 1
            else:
                break

        # If the number of collected folds is not at least 75% of the
        # expected number, then raise an exception
        if folds_collected >= 0.75*folds:
            return training_set
        else:
            raise ValueError('Could not generate a {0} data-set consisting of '
                             'at least 75% of the desired size ({1}).'
                             .format('grid search' if grid_search else 'training',
                                     folds))

    def _construct_layered_dataset(self):
        """
        Build up a main training set consisting of multiple folds and
        possibly a grid search dataset containing samples from the same
        set of games as the main training set, which will also consist
        of multiple folds, and a test set consisting of samples from
        either the same games as the training/grid search set in
        addition to other games or a set of games that has no overlap
        with the training/grid search sets at all.
        """

        # Generate a list of sample IDs for the test set, if applicable
        if self.test_size:
            self.test_set = self._make_test_set()

        # Get dictionary of ID strings mapped to labels and a frequency
        # distribution of the labels (if not cached while making the
        # test set)
        if not (self.id_strings_labels and self.labels_fdist):
            distribution_data = distributional_info(self.db,
                                                    self.prediction_label,
                                                    list(self.games),
                                                    **self.distributional_info_kwargs)
            self.id_strings_labels = distribution_data['id_strings_labels_dict']
            self.labels_fdist = distribution_data['labels_fdist']

        # Remove sample IDs that are in the test set, if any and if
        # there are even games in common between the test set and the
        # training set
        if self.test_size and any(game in self.games for game in self.test_games):
            for _id in self.test_set:
                if _id in self.id_strings_labels:
                    del self.id_strings_labels[_id]

        # Get set of labels
        self.labels = set(self.labels_fdist)

        # Make a dictionary mapping each label value to a list of
        # sample IDs
        self.labels_id_strings = self._generate_labels_dict()

        # Generate arrays of sample IDs for the main training data-set
        # folds
        if self.folds:
            self.training_set = self._generate_dataset()

        # Generate arrays of sample IDs for the grid search folds
        if self.grid_search_folds:
            self.grid_search_set = self._generate_dataset(grid_search=True)

        # Set the `self.num_datasets` attribute
        self.num_datasets = len(self.training_set)
